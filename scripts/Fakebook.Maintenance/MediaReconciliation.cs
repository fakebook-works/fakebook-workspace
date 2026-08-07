using System.Data;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using Npgsql;

internal sealed record MediaReconciliationOptions(
    string UploadPath,
    IReadOnlyList<string> AllowedOrigins,
    bool WritersStopped,
    bool ServingStopped,
    bool AcquireExclusiveLock,
    string? ManifestOutput,
    string? ReceiptOutput,
    string? VerifyManifest);

internal sealed record MediaReconciliationRunResult(
    MediaReconciliationSummary Summary,
    int ExitCode);

internal sealed record MediaReconciliationSelfTestResult(
    bool Success,
    int TestCount,
    IReadOnlyList<string> FailedTests);

internal sealed record MediaReconciliationSummary(
    bool Success,
    bool DryRun,
    bool MigrationRequired,
    bool FutureApplyPreconditionsSatisfied,
    string ManifestSha256,
    int AssetCount,
    int ReferenceCount,
    int ReadyAssetCount,
    int MigrationAssetCount,
    int UnreferencedAssetCount,
    int PreservedPendingAssetCount,
    int ManualReviewAssetCount,
    long OutstandingLegacyOutboxCount,
    long OutstandingExactOutboxCount,
    long SuspectedWriterSessionCount,
    int IgnoredExternalMediaCount,
    int InvalidManagedMediaCount,
    IReadOnlyList<string> BlockingFindings,
    bool ManifestWritten,
    bool ReceiptWritten,
    bool? VerificationMatched);

internal sealed record MediaReconciliationManifest(
    int SchemaVersion,
    string DatabaseFingerprint,
    string StorageRootFingerprint,
    bool ContainsSensitiveIdentifiers,
    bool WritersStoppedAcknowledged,
    bool ServingStoppedAcknowledged,
    bool ExclusiveStorageLockHeld,
    IReadOnlyList<MediaReconciliationAsset> Assets);

internal sealed record MediaReconciliationAsset(
    string AssetId,
    string StoredName,
    IReadOnlyList<string> ExpectedReferences,
    bool PhysicalFilePresent,
    string MetadataStatus,
    int? LifecycleVersion,
    bool? LegacyPinned,
    string Classification,
    IReadOnlyList<string> ReviewReasons);

internal sealed record MediaReconciliationReceipt(
    int SchemaVersion,
    string DatabaseFingerprint,
    string StorageRootFingerprint,
    string ManifestSha256,
    int AssetCount,
    int ReferenceCount,
    int MigrationAssetCount,
    int UnreferencedAssetCount,
    int ManualReviewAssetCount,
    long OutstandingLegacyOutboxCount,
    long OutstandingExactOutboxCount,
    bool FutureApplyPreconditionsSatisfied);

internal enum ManagedMediaLocationKind
{
    Managed,
    External,
    InvalidManaged
}

internal sealed record ManagedMediaLocation(
    ManagedMediaLocationKind Kind,
    string? AssetId = null,
    string? StoredName = null);

internal static class MediaReconciliation
{
    private const int ManifestSchemaVersion = 1;
    private const int CurrentLifecycleVersion = 3;
    private const long MaxMetadataBytes = 2L * 1024 * 1024;
    private const int MaxManifestAssets = 1_000_000;
    private static readonly JsonSerializerOptions ManifestJson = new(JsonSerializerDefaults.Web)
    {
        WriteIndented = true
    };

    internal static async Task<MediaReconciliationRunResult> RunAsync(
        NpgsqlConnection connection,
        string databaseFingerprint,
        MediaReconciliationOptions options,
        CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(connection);
        ArgumentException.ThrowIfNullOrWhiteSpace(databaseFingerprint);
        ArgumentNullException.ThrowIfNull(options);

        var uploadRoot = Path.GetFullPath(options.UploadPath);
        if (!Directory.Exists(uploadRoot))
        {
            throw new InvalidOperationException("The media reconciliation upload path does not exist.");
        }

        EnsureOutputOutsideStorage(uploadRoot, options.ManifestOutput, "manifest");
        EnsureOutputOutsideStorage(uploadRoot, options.ReceiptOutput, "receipt");
        var allowedOrigins = NormalizeAllowedOrigins(options.AllowedOrigins);
        var blockers = new SortedSet<string>(StringComparer.Ordinal);
        var accumulator = new ReferenceAccumulator(allowedOrigins, blockers);

        await using var storageLock = options.AcquireExclusiveLock
            ? await MediaStorageExclusiveLock.AcquireAsync(uploadRoot, cancellationToken)
            : null;

        if (options.AcquireExclusiveLock && (!options.WritersStopped || !options.ServingStopped))
        {
            blockers.Add("exclusive-lock-requires-writers-and-serving-stopped-acknowledgements");
        }

        var requiredTables = new[]
        {
            "social_graph.objects",
            "social_graph.associations",
            "social_graph.integration_outbox",
            "messenger.conversations",
            "messenger.message_attachments",
            "messenger.outbox_events"
        };
        var availableTables = await ReadAvailableTablesAsync(connection, requiredTables, cancellationToken);
        foreach (var missing in requiredTables.Where(table => !availableTables.Contains(table)))
        {
            blockers.Add("missing-required-table:" + missing);
        }

        long suspectedWriterSessions;
        OutboxAudit outboxAudit;
        await using (var transaction = await connection.BeginTransactionAsync(
                         IsolationLevel.RepeatableRead,
                         cancellationToken))
        {
            await using (var readOnly = new NpgsqlCommand("SET TRANSACTION READ ONLY;", connection, transaction))
            {
                await readOnly.ExecuteNonQueryAsync(cancellationToken);
            }

            suspectedWriterSessions = await CountSuspectedWriterSessionsAsync(
                connection,
                transaction,
                cancellationToken);
            if (options.WritersStopped && suspectedWriterSessions > 0)
            {
                blockers.Add("runtime-database-sessions-remain-after-writers-stopped-acknowledgement");
            }

            if (availableTables.Contains("social_graph.objects") &&
                availableTables.Contains("social_graph.associations"))
            {
                await ReadSocialGraphReferencesAsync(
                    connection,
                    transaction,
                    accumulator,
                    cancellationToken);
            }

            if (availableTables.Contains("messenger.message_attachments"))
            {
                await ReadMessengerAttachmentReferencesAsync(
                    connection,
                    transaction,
                    accumulator,
                    cancellationToken);
            }

            if (availableTables.Contains("messenger.conversations"))
            {
                await ReadMessengerConversationReferencesAsync(
                    connection,
                    transaction,
                    accumulator,
                    cancellationToken);
            }

            outboxAudit = await ReadOutboxAuditAsync(
                connection,
                transaction,
                availableTables,
                cancellationToken);
            await transaction.CommitAsync(cancellationToken);
        }

        if (outboxAudit.LegacyCount > 0)
        {
            blockers.Add("outstanding-legacy-url-lifecycle-outbox-rows");
        }
        if (outboxAudit.ExactCount > 0)
        {
            // Exact rows are safe during normal operation, but a future authoritative
            // offline rewrite must use a drained queue or replay can change its snapshot.
            blockers.Add("outstanding-exact-lifecycle-outbox-rows");
        }
        if (outboxAudit.InvalidCount > 0)
        {
            blockers.Add("invalid-or-mixed-media-lifecycle-outbox-rows");
        }

        var storage = ScanStorage(uploadRoot, accumulator.Assets, blockers);
        var assets = BuildManifestAssets(accumulator.Assets, storage, blockers);
        if (assets.Count > MaxManifestAssets)
        {
            throw new InvalidOperationException(
                $"Media reconciliation refuses manifests larger than {MaxManifestAssets} assets.");
        }

        var storageFingerprint = Sha256Hex(Encoding.UTF8.GetBytes(NormalizePathForFingerprint(uploadRoot)));
        var manifest = CanonicalizeManifest(new MediaReconciliationManifest(
            ManifestSchemaVersion,
            databaseFingerprint,
            storageFingerprint,
            ContainsSensitiveIdentifiers: true,
            options.WritersStopped,
            options.ServingStopped,
            storageLock is not null,
            assets));
        var manifestBytes = SerializeManifest(manifest);
        var manifestHash = Sha256Hex(manifestBytes);

        bool? verificationMatched = null;
        if (!string.IsNullOrWhiteSpace(options.VerifyManifest))
        {
            var verificationPath = Path.GetFullPath(options.VerifyManifest);
            if (!File.Exists(verificationPath))
            {
                blockers.Add("verification-manifest-missing");
                verificationMatched = false;
            }
            else
            {
                var expectedBytes = await File.ReadAllBytesAsync(verificationPath, cancellationToken);
                verificationMatched = CryptographicOperations.FixedTimeEquals(
                    SHA256.HashData(expectedBytes),
                    SHA256.HashData(manifestBytes));
                if (verificationMatched != true)
                {
                    blockers.Add("verification-manifest-does-not-match-current-snapshot");
                }
            }
        }

        var manifestWritten = false;
        if (!string.IsNullOrWhiteSpace(options.ManifestOutput))
        {
            await AtomicWriteAsync(
                Path.GetFullPath(options.ManifestOutput),
                manifestBytes,
                sensitive: true,
                cancellationToken);
            manifestWritten = true;
        }

        var readyCount = assets.Count(asset => asset.Classification == "ready-exact");
        var migrationCount = assets.Count(asset => asset.Classification is
            "migrate-legacy" or "reconcile-exact" or "migrate-live-parent");
        var unreferencedCount = assets.Count(asset => asset.Classification is
            "delete-unreferenced" or "metadata-only");
        var pendingCount = assets.Count(asset => asset.Classification == "preserve-staged");
        var manualCount = assets.Count(asset => asset.Classification == "manual-review");
        var referenceCount = assets.Sum(asset => asset.ExpectedReferences.Count);
        var futureApplyReady = options.WritersStopped &&
                               options.ServingStopped &&
                               storageLock is not null &&
                               blockers.Count == 0 &&
                               manualCount == 0 &&
                               outboxAudit.LegacyCount == 0 &&
                               outboxAudit.ExactCount == 0;
        var migrationRequired = migrationCount > 0 || unreferencedCount > 0;

        var receipt = new MediaReconciliationReceipt(
            ManifestSchemaVersion,
            databaseFingerprint,
            storageFingerprint,
            manifestHash,
            assets.Count,
            referenceCount,
            migrationCount,
            unreferencedCount,
            manualCount,
            outboxAudit.LegacyCount,
            outboxAudit.ExactCount,
            futureApplyReady);
        var receiptWritten = false;
        if (!string.IsNullOrWhiteSpace(options.ReceiptOutput))
        {
            await AtomicWriteAsync(
                Path.GetFullPath(options.ReceiptOutput),
                JsonSerializer.SerializeToUtf8Bytes(receipt, ManifestJson),
                sensitive: false,
                cancellationToken);
            receiptWritten = true;
        }

        var summary = new MediaReconciliationSummary(
            Success: blockers.Count == 0 && manualCount == 0,
            DryRun: true,
            MigrationRequired: migrationRequired,
            FutureApplyPreconditionsSatisfied: futureApplyReady,
            ManifestSha256: manifestHash,
            AssetCount: assets.Count,
            ReferenceCount: referenceCount,
            ReadyAssetCount: readyCount,
            MigrationAssetCount: migrationCount,
            UnreferencedAssetCount: unreferencedCount,
            PreservedPendingAssetCount: pendingCount,
            ManualReviewAssetCount: manualCount,
            OutstandingLegacyOutboxCount: outboxAudit.LegacyCount,
            OutstandingExactOutboxCount: outboxAudit.ExactCount,
            SuspectedWriterSessionCount: suspectedWriterSessions,
            IgnoredExternalMediaCount: accumulator.IgnoredExternalCount,
            InvalidManagedMediaCount: accumulator.InvalidManagedCount,
            BlockingFindings: blockers.ToArray(),
            ManifestWritten: manifestWritten,
            ReceiptWritten: receiptWritten,
            VerificationMatched: verificationMatched);

        return new MediaReconciliationRunResult(
            summary,
            summary.Success && verificationMatched is not false ? 0 : 2);
    }

    internal static ManagedMediaLocation NormalizeManagedMediaLocation(
        string? value,
        IReadOnlySet<string> allowedOrigins)
    {
        if (string.IsNullOrWhiteSpace(value))
        {
            return new ManagedMediaLocation(ManagedMediaLocationKind.External);
        }

        var candidate = value.Trim();
        string path;
        // Unix treats a leading slash as an absolute file: URI. Root-relative managed
        // application paths are not filesystem URLs and must be handled first.
        if (candidate.StartsWith("/media/files/", StringComparison.OrdinalIgnoreCase))
        {
            path = candidate.Split('?', '#')[0];
        }
        else if (Uri.TryCreate(candidate, UriKind.Absolute, out var absolute))
        {
            path = absolute.AbsolutePath;
            if (!path.StartsWith("/media/files/", StringComparison.OrdinalIgnoreCase))
            {
                return new ManagedMediaLocation(ManagedMediaLocationKind.External);
            }
            if (absolute.Scheme is not ("http" or "https") ||
                !string.IsNullOrEmpty(absolute.UserInfo) ||
                !allowedOrigins.Contains(absolute.GetLeftPart(UriPartial.Authority).TrimEnd('/')))
            {
                return new ManagedMediaLocation(ManagedMediaLocationKind.InvalidManaged);
            }
        }
        else
        {
            path = candidate.Split('?', '#')[0];
            if (!path.StartsWith("/media/files/", StringComparison.OrdinalIgnoreCase))
            {
                return new ManagedMediaLocation(ManagedMediaLocationKind.External);
            }
        }

        string storedName;
        try
        {
            storedName = Uri.UnescapeDataString(path["/media/files/".Length..]);
        }
        catch (UriFormatException)
        {
            return new ManagedMediaLocation(ManagedMediaLocationKind.InvalidManaged);
        }

        if (!IsSafeStoredName(storedName, out var assetId))
        {
            return new ManagedMediaLocation(ManagedMediaLocationKind.InvalidManaged);
        }
        return new ManagedMediaLocation(ManagedMediaLocationKind.Managed, assetId, storedName);
    }

    internal static MediaReconciliationManifest CanonicalizeManifest(MediaReconciliationManifest manifest) =>
        manifest with
        {
            Assets = manifest.Assets
                .Select(asset => asset with
                {
                    ExpectedReferences = asset.ExpectedReferences
                        .Distinct(StringComparer.Ordinal)
                        .OrderBy(reference => reference, StringComparer.Ordinal)
                        .ToArray(),
                    ReviewReasons = asset.ReviewReasons
                        .Distinct(StringComparer.Ordinal)
                        .OrderBy(reason => reason, StringComparer.Ordinal)
                        .ToArray()
                })
                .OrderBy(asset => asset.AssetId, StringComparer.Ordinal)
                .ThenBy(asset => asset.StoredName, StringComparer.Ordinal)
                .ToArray()
        };

    internal static byte[] SerializeManifest(MediaReconciliationManifest manifest) =>
        JsonSerializer.SerializeToUtf8Bytes(CanonicalizeManifest(manifest), ManifestJson);

    internal static MediaReconciliationSelfTestResult RunSelfTest()
    {
        const string assetA = "00112233445566778899aabbccddeeff";
        const string assetB = "ffeeddccbbaa99887766554433221100";
        var allowedOrigins = new HashSet<string>(StringComparer.OrdinalIgnoreCase)
        {
            "https://fakebook.example"
        };
        var failures = new List<string>();
        var tests = 0;

        Check(
            "relative-managed-location",
            NormalizeManagedMediaLocation($"/media/files/{assetA}.avif", allowedOrigins) is
                { Kind: ManagedMediaLocationKind.Managed, AssetId: assetA },
            failures,
            ref tests);
        Check(
            "allowed-absolute-managed-location",
            NormalizeManagedMediaLocation(
                $"https://fakebook.example/media/files/{assetA}.avif?version=1",
                allowedOrigins) is { Kind: ManagedMediaLocationKind.Managed, AssetId: assetA },
            failures,
            ref tests);
        Check(
            "foreign-managed-origin-blocked",
            NormalizeManagedMediaLocation(
                $"https://foreign.example/media/files/{assetA}.avif",
                allowedOrigins).Kind == ManagedMediaLocationKind.InvalidManaged,
            failures,
            ref tests);
        Check(
            "external-url-ignored",
            NormalizeManagedMediaLocation(
                "https://cdn.example/unmanaged/image.avif",
                allowedOrigins).Kind == ManagedMediaLocationKind.External,
            failures,
            ref tests);
        Check(
            "encoded-path-separator-blocked",
            NormalizeManagedMediaLocation(
                $"https://fakebook.example/media/files/{assetA}.avif%5Cother.jpg",
                allowedOrigins).Kind == ManagedMediaLocationKind.InvalidManaged,
            failures,
            ref tests);

        var first = new MediaReconciliationManifest(
            1,
            "database-fingerprint",
            "storage-fingerprint",
            true,
            false,
            false,
            false,
            [
                new MediaReconciliationAsset(
                    assetB,
                    assetB + ".avif",
                    ["socialgraph:media:2", "socialgraph:media:1", "socialgraph:media:2"],
                    true,
                    "loaded",
                    3,
                    false,
                    "ready-exact",
                    ["reason-b", "reason-a", "reason-b"]),
                new MediaReconciliationAsset(
                    assetA,
                    assetA + ".avif",
                    ["messenger:message:abc:attachment:0:content"],
                    true,
                    "loaded",
                    3,
                    false,
                    "ready-exact",
                    [])
            ]);
        var second = first with
        {
            Assets = first.Assets.Reverse().Select(asset => asset with
            {
                ExpectedReferences = asset.ExpectedReferences.Reverse().ToArray(),
                ReviewReasons = asset.ReviewReasons.Reverse().ToArray()
            }).ToArray()
        };
        Check(
            "canonical-manifest-deterministic",
            SerializeManifest(first).AsSpan().SequenceEqual(SerializeManifest(second)),
            failures,
            ref tests);

        var blockers = new SortedSet<string>(StringComparer.Ordinal);
        var accumulator = new ReferenceAccumulator(allowedOrigins, blockers);
        accumulator.Add(
            $"https://foreign.example/media/files/{assetA}.avif",
            "socialgraph:media:1");
        Check(
            "invalid-managed-location-adds-blocker",
            blockers.Contains("database-managed-media-location-invalid") &&
            accumulator.InvalidManagedCount == 1,
            failures,
            ref tests);

        return new MediaReconciliationSelfTestResult(failures.Count == 0, tests, failures);
    }

    private static void Check(
        string name,
        bool condition,
        ICollection<string> failures,
        ref int testCount)
    {
        testCount++;
        if (!condition)
        {
            failures.Add(name);
        }
    }

    private static async Task<HashSet<string>> ReadAvailableTablesAsync(
        NpgsqlConnection connection,
        IReadOnlyList<string> requiredTables,
        CancellationToken cancellationToken)
    {
        var available = new HashSet<string>(StringComparer.Ordinal);
        foreach (var table in requiredTables)
        {
            await using var command = new NpgsqlCommand(
                "SELECT to_regclass(@table) IS NOT NULL;",
                connection);
            command.Parameters.AddWithValue("table", table);
            if (Convert.ToBoolean(await command.ExecuteScalarAsync(cancellationToken)))
            {
                available.Add(table);
            }
        }
        return available;
    }

    private static async Task<long> CountSuspectedWriterSessionsAsync(
        NpgsqlConnection connection,
        NpgsqlTransaction transaction,
        CancellationToken cancellationToken)
    {
        await using var command = new NpgsqlCommand(
            """
            SELECT count(*)
            FROM pg_stat_activity
            WHERE pid <> pg_backend_pid()
              AND backend_type = 'client backend'
              AND (
                    usename LIKE 'fakebook\_%' ESCAPE '\'
                    OR application_name LIKE 'fakebook-%'
                  );
            """,
            connection,
            transaction);
        return Convert.ToInt64(await command.ExecuteScalarAsync(cancellationToken));
    }

    private static async Task ReadSocialGraphReferencesAsync(
        NpgsqlConnection connection,
        NpgsqlTransaction transaction,
        ReferenceAccumulator accumulator,
        CancellationToken cancellationToken)
    {
        await using (var command = new NpgsqlCommand(
            """
            SELECT media.id, media.data ->> 'url'
            FROM social_graph.objects AS media
            WHERE media.otype = 7
              AND EXISTS (
                  SELECT 1
                  FROM social_graph.associations AS contained
                  WHERE contained.atype = 28 AND contained.id2 = media.id
              )
            ORDER BY media.id;
            """,
            connection,
            transaction))
        await using (var reader = await command.ExecuteReaderAsync(cancellationToken))
        {
            while (await reader.ReadAsync(cancellationToken))
            {
                accumulator.Add(
                    reader.IsDBNull(1) ? null : reader.GetString(1),
                    $"socialgraph:media:{reader.GetInt64(0)}");
            }
        }

        await ReadObjectSlotReferencesAsync(
            connection,
            transaction,
            objectType: 0,
            objectPrefix: "user",
            accumulator,
            cancellationToken);
        await ReadObjectSlotReferencesAsync(
            connection,
            transaction,
            objectType: 1,
            objectPrefix: "group",
            accumulator,
            cancellationToken);
    }

    private static async Task ReadObjectSlotReferencesAsync(
        NpgsqlConnection connection,
        NpgsqlTransaction transaction,
        short objectType,
        string objectPrefix,
        ReferenceAccumulator accumulator,
        CancellationToken cancellationToken)
    {
        await using var command = new NpgsqlCommand(
            """
            SELECT id, data ->> 'avatar', data ->> 'background'
            FROM social_graph.objects
            WHERE otype = @otype
            ORDER BY id;
            """,
            connection,
            transaction);
        command.Parameters.AddWithValue("otype", objectType);
        await using var reader = await command.ExecuteReaderAsync(cancellationToken);
        while (await reader.ReadAsync(cancellationToken))
        {
            var id = reader.GetInt64(0).ToString();
            if (!reader.IsDBNull(1))
            {
                accumulator.Add(reader.GetString(1), $"socialgraph:{objectPrefix}:{id}:avatar");
            }
            if (!reader.IsDBNull(2))
            {
                accumulator.Add(reader.GetString(2), $"socialgraph:{objectPrefix}:{id}:background");
            }
        }
    }

    private static async Task ReadMessengerAttachmentReferencesAsync(
        NpgsqlConnection connection,
        NpgsqlTransaction transaction,
        ReferenceAccumulator accumulator,
        CancellationToken cancellationToken)
    {
        await using var command = new NpgsqlCommand(
            """
            SELECT message_id, ordinal, url, thumbnail_url
            FROM messenger.message_attachments
            ORDER BY message_id, ordinal;
            """,
            connection,
            transaction);
        await using var reader = await command.ExecuteReaderAsync(cancellationToken);
        while (await reader.ReadAsync(cancellationToken))
        {
            var messageId = reader.GetGuid(0).ToString("N");
            var ordinal = reader.GetInt32(1);
            accumulator.Add(
                reader.GetString(2),
                $"messenger:message:{messageId}:attachment:{ordinal}:content");
            if (!reader.IsDBNull(3))
            {
                accumulator.Add(
                    reader.GetString(3),
                    $"messenger:message:{messageId}:attachment:{ordinal}:thumbnail");
            }
        }
    }

    private static async Task ReadMessengerConversationReferencesAsync(
        NpgsqlConnection connection,
        NpgsqlTransaction transaction,
        ReferenceAccumulator accumulator,
        CancellationToken cancellationToken)
    {
        await using var command = new NpgsqlCommand(
            """
            SELECT id, avatar_url
            FROM messenger.conversations
            WHERE avatar_url IS NOT NULL AND btrim(avatar_url) <> ''
            ORDER BY id;
            """,
            connection,
            transaction);
        await using var reader = await command.ExecuteReaderAsync(cancellationToken);
        while (await reader.ReadAsync(cancellationToken))
        {
            accumulator.Add(
                reader.GetString(1),
                $"messenger:conversation:{reader.GetGuid(0):N}:avatar");
        }
    }

    private static async Task<OutboxAudit> ReadOutboxAuditAsync(
        NpgsqlConnection connection,
        NpgsqlTransaction transaction,
        IReadOnlySet<string> availableTables,
        CancellationToken cancellationToken)
    {
        var total = new OutboxAudit(0, 0, 0);
        if (availableTables.Contains("social_graph.integration_outbox"))
        {
            total += await ReadOneOutboxAuditAsync(
                connection,
                transaction,
                """
                WITH rows AS (
                    SELECT
                        CASE WHEN jsonb_typeof(payload -> 'urls') = 'array'
                             THEN jsonb_array_length(payload -> 'urls') ELSE 0 END AS urls_count,
                        CASE WHEN jsonb_typeof(payload -> 'references') = 'array'
                             THEN jsonb_array_length(payload -> 'references') ELSE 0 END AS refs_count
                    FROM social_graph.integration_outbox
                    WHERE event_type IN ('media.finalize.v1', 'media.delete.v1')
                      AND status <> 2
                )
                SELECT
                    count(*) FILTER (WHERE urls_count > 0),
                    count(*) FILTER (WHERE refs_count > 0),
                    count(*) FILTER (WHERE (urls_count > 0 AND refs_count > 0)
                                           OR (urls_count = 0 AND refs_count = 0))
                FROM rows;
                """,
                cancellationToken);
        }
        if (availableTables.Contains("messenger.outbox_events"))
        {
            total += await ReadOneOutboxAuditAsync(
                connection,
                transaction,
                """
                WITH rows AS (
                    SELECT
                        CASE WHEN jsonb_typeof(payload_json -> 'urls') = 'array'
                             THEN jsonb_array_length(payload_json -> 'urls') ELSE 0 END AS urls_count,
                        CASE WHEN jsonb_typeof(payload_json -> 'references') = 'array'
                             THEN jsonb_array_length(payload_json -> 'references') ELSE 0 END AS refs_count
                    FROM messenger.outbox_events
                    WHERE kind IN ('media.finalize.v1', 'media.delete.v1')
                      AND processed_at IS NULL
                )
                SELECT
                    count(*) FILTER (WHERE urls_count > 0),
                    count(*) FILTER (WHERE refs_count > 0),
                    count(*) FILTER (WHERE (urls_count > 0 AND refs_count > 0)
                                           OR (urls_count = 0 AND refs_count = 0))
                FROM rows;
                """,
                cancellationToken);
        }
        return total;
    }

    private static async Task<OutboxAudit> ReadOneOutboxAuditAsync(
        NpgsqlConnection connection,
        NpgsqlTransaction transaction,
        string sql,
        CancellationToken cancellationToken)
    {
        await using var command = new NpgsqlCommand(sql, connection, transaction);
        await using var reader = await command.ExecuteReaderAsync(cancellationToken);
        if (!await reader.ReadAsync(cancellationToken))
        {
            return new OutboxAudit(0, 0, 0);
        }
        return new OutboxAudit(reader.GetInt64(0), reader.GetInt64(1), reader.GetInt64(2));
    }

    private static StorageSnapshot ScanStorage(
        string uploadRoot,
        IReadOnlyDictionary<string, ExpectedAsset> expectedAssets,
        ISet<string> blockers)
    {
        var physical = new Dictionary<string, List<string>>(StringComparer.OrdinalIgnoreCase);
        var unknownTopLevelFiles = 0;
        foreach (var path in Directory.EnumerateFiles(uploadRoot, "*", SearchOption.TopDirectoryOnly))
        {
            var storedName = Path.GetFileName(path);
            if (!IsSafeStoredName(storedName, out var assetId))
            {
                unknownTopLevelFiles++;
                continue;
            }
            if (!physical.TryGetValue(assetId, out var names))
            {
                physical[assetId] = names = [];
            }
            names.Add(storedName);
        }
        if (unknownTopLevelFiles > 0)
        {
            blockers.Add("unknown-top-level-storage-files:" + unknownTopLevelFiles);
        }

        var metadata = new Dictionary<string, MetadataProbe>(StringComparer.OrdinalIgnoreCase);
        var metadataRoot = Path.Combine(uploadRoot, ".metadata");
        if (!Directory.Exists(metadataRoot))
        {
            if (expectedAssets.Count > 0 || physical.Count > 0)
            {
                blockers.Add("metadata-directory-missing");
            }
            return new StorageSnapshot(physical, metadata);
        }

        var invalidMetadataNames = 0;
        foreach (var metadataPath in Directory.EnumerateFiles(metadataRoot, "*.json", SearchOption.TopDirectoryOnly))
        {
            var assetId = Path.GetFileNameWithoutExtension(metadataPath);
            if (!Guid.TryParseExact(assetId, "N", out _))
            {
                invalidMetadataNames++;
                continue;
            }
            metadata[assetId] = ReadMetadataProbe(metadataPath, assetId);
        }
        if (invalidMetadataNames > 0)
        {
            blockers.Add("invalid-metadata-file-names:" + invalidMetadataNames);
        }
        return new StorageSnapshot(physical, metadata);
    }

    private static MetadataProbe ReadMetadataProbe(string path, string expectedAssetId)
    {
        try
        {
            var info = new FileInfo(path);
            if (info.Length is <= 0 or > MaxMetadataBytes)
            {
                return MetadataProbe.Corrupt;
            }
            using var document = JsonDocument.Parse(File.ReadAllBytes(path));
            var root = document.RootElement;
            var assetId = GetString(root, "assetId");
            var storedName = GetString(root, "storedName");
            var state = GetString(root, "state");
            if (!string.Equals(assetId, expectedAssetId, StringComparison.OrdinalIgnoreCase) ||
                string.IsNullOrWhiteSpace(storedName) ||
                !IsSafeStoredName(storedName, out var storedAssetId) ||
                !string.Equals(storedAssetId, expectedAssetId, StringComparison.OrdinalIgnoreCase) ||
                state is not ("pending" or "committed" or "deleted"))
            {
                return MetadataProbe.Corrupt;
            }

            var owner = GetInt64(root, "ownerUserId");
            var lifecycle = GetInt32(root, "lifecycleVersion") ?? 0;
            var legacyPinned = GetBoolean(root, "legacyPinned") ?? false;
            var hasWatermark = HasNonNullProperty(root, "releasedReferenceWatermark");
            var active = GetObjectPropertyNames(root, "activeReferences");
            var pendingCount = GetObjectPropertyCount(root, "pendingReferences");
            var hasReservation = HasNonNullProperty(root, "reservedAt") ||
                                 HasNonNullProperty(root, "reservationExpiresAt");
            return new MetadataProbe(
                "loaded",
                storedName,
                state,
                lifecycle,
                legacyPinned,
                owner,
                active,
                pendingCount,
                hasReservation,
                lifecycle < CurrentLifecycleVersion || legacyPinned || hasWatermark);
        }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException or JsonException)
        {
            return MetadataProbe.Corrupt;
        }
    }

    private static IReadOnlyList<MediaReconciliationAsset> BuildManifestAssets(
        IReadOnlyDictionary<string, ExpectedAsset> expected,
        StorageSnapshot storage,
        ISet<string> blockers)
    {
        var ids = expected.Keys
            .Concat(storage.Metadata.Keys)
            .Concat(storage.Physical.Keys)
            .Distinct(StringComparer.OrdinalIgnoreCase)
            .OrderBy(value => value, StringComparer.Ordinal)
            .ToArray();
        var result = new List<MediaReconciliationAsset>(ids.Length);
        foreach (var assetId in ids)
        {
            expected.TryGetValue(assetId, out var expectedAsset);
            storage.Metadata.TryGetValue(assetId, out var metadata);
            storage.Physical.TryGetValue(assetId, out var physicalNames);
            physicalNames ??= [];
            var reasons = new SortedSet<string>(StringComparer.Ordinal);
            if (physicalNames.Count > 1)
            {
                reasons.Add("multiple-physical-files-for-one-asset-id");
            }

            var storedName = expectedAsset?.StoredName ??
                             metadata?.StoredName ??
                             physicalNames.OrderBy(value => value, StringComparer.Ordinal).FirstOrDefault() ??
                             assetId + ".unknown";
            if (expectedAsset is not null && metadata?.StoredName is not null &&
                !string.Equals(expectedAsset.StoredName, metadata.StoredName, StringComparison.OrdinalIgnoreCase))
            {
                reasons.Add("database-and-metadata-stored-name-mismatch");
            }

            var filePresent = physicalNames.Any(value =>
                string.Equals(value, storedName, StringComparison.OrdinalIgnoreCase));
            var expectedReferences = expectedAsset?.References
                .OrderBy(value => value, StringComparer.Ordinal)
                .ToArray() ?? [];

            string classification;
            if (metadata is null)
            {
                reasons.Add("metadata-missing");
                classification = "manual-review";
            }
            else if (metadata.Status != "loaded")
            {
                reasons.Add("metadata-corrupt-or-unreadable");
                classification = "manual-review";
            }
            else if (expectedReferences.Length > 0 && !filePresent)
            {
                reasons.Add("live-parent-file-missing");
                classification = "manual-review";
            }
            else if (metadata.State != "deleted" && metadata.OwnerUserId <= 0)
            {
                reasons.Add("nondeleted-metadata-owner-invalid");
                classification = "manual-review";
            }
            else if (metadata.ActiveReferences.Any(reference =>
                         !reference.StartsWith("socialgraph:", StringComparison.Ordinal) &&
                         !reference.StartsWith("messenger:", StringComparison.Ordinal)))
            {
                reasons.Add("unknown-active-reference-namespace");
                classification = "manual-review";
            }
            else if (metadata.State == "deleted" && expectedReferences.Length > 0)
            {
                reasons.Add("deleted-asset-still-has-live-database-parent");
                classification = "manual-review";
            }
            else if (metadata.State == "deleted")
            {
                classification = "already-deleted";
            }
            else if (metadata.State == "pending" && expectedReferences.Length == 0)
            {
                classification = "preserve-staged";
            }
            else if (metadata.State == "pending")
            {
                classification = "migrate-live-parent";
            }
            else if (expectedReferences.Length == 0 && !filePresent)
            {
                classification = "metadata-only";
            }
            else if (expectedReferences.Length == 0)
            {
                classification = "delete-unreferenced";
            }
            else if (metadata.IsLegacy)
            {
                classification = "migrate-legacy";
            }
            else if (!metadata.ActiveReferences.ToHashSet(StringComparer.Ordinal)
                         .SetEquals(expectedReferences))
            {
                classification = "reconcile-exact";
            }
            else
            {
                classification = "ready-exact";
            }

            if (classification == "manual-review")
            {
                blockers.Add("assets-require-manual-review");
            }
            result.Add(new MediaReconciliationAsset(
                assetId,
                storedName,
                expectedReferences,
                filePresent,
                metadata?.Status ?? "missing",
                metadata?.LifecycleVersion,
                metadata?.LegacyPinned,
                classification,
                reasons.ToArray()));
        }
        return result;
    }

    private static HashSet<string> NormalizeAllowedOrigins(IEnumerable<string> values)
    {
        var result = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        foreach (var value in values.Where(value => !string.IsNullOrWhiteSpace(value)))
        {
            if (!Uri.TryCreate(value.Trim(), UriKind.Absolute, out var uri) ||
                uri.Scheme is not ("http" or "https") ||
                !string.IsNullOrEmpty(uri.UserInfo) ||
                uri.AbsolutePath != "/" ||
                !string.IsNullOrEmpty(uri.Query) ||
                !string.IsNullOrEmpty(uri.Fragment))
            {
                throw new InvalidOperationException(
                    "Every media reconciliation allowed origin must be an HTTP(S) origin without credentials, path, query, or fragment.");
            }
            result.Add(uri.GetLeftPart(UriPartial.Authority).TrimEnd('/'));
        }
        return result;
    }

    private static bool IsSafeStoredName(string storedName, out string assetId)
    {
        assetId = Path.GetFileNameWithoutExtension(storedName);
        return storedName.Length is > 0 and <= 255 &&
               !storedName.Contains('/') &&
               !storedName.Contains('\\') &&
               string.Equals(Path.GetFileName(storedName), storedName, StringComparison.Ordinal) &&
               !storedName.Contains("..", StringComparison.Ordinal) &&
               !string.IsNullOrEmpty(Path.GetExtension(storedName)) &&
               Guid.TryParseExact(assetId, "N", out _);
    }

    private static void EnsureOutputOutsideStorage(string root, string? output, string label)
    {
        if (string.IsNullOrWhiteSpace(output))
        {
            return;
        }
        var full = Path.GetFullPath(output);
        var relative = Path.GetRelativePath(root, full);
        if (!relative.StartsWith(".." + Path.DirectorySeparatorChar, StringComparison.Ordinal) &&
            relative != ".." &&
            !Path.IsPathRooted(relative))
        {
            throw new InvalidOperationException($"The {label} output must be outside Upload storage.");
        }
    }

    private static async Task AtomicWriteAsync(
        string path,
        byte[] bytes,
        bool sensitive,
        CancellationToken cancellationToken)
    {
        var directory = Path.GetDirectoryName(path);
        if (string.IsNullOrWhiteSpace(directory))
        {
            throw new InvalidOperationException("Output path has no parent directory.");
        }
        Directory.CreateDirectory(directory);
        var temporary = path + ".tmp-" + Guid.NewGuid().ToString("N");
        try
        {
            await using (var stream = new FileStream(
                             temporary,
                             FileMode.CreateNew,
                             FileAccess.Write,
                             FileShare.None,
                             64 * 1024,
                             FileOptions.Asynchronous | FileOptions.WriteThrough))
            {
                await stream.WriteAsync(bytes, cancellationToken);
                await stream.FlushAsync(cancellationToken);
                stream.Flush(flushToDisk: true);
            }
            File.Move(temporary, path, overwrite: true);
            if (sensitive && !OperatingSystem.IsWindows())
            {
                File.SetUnixFileMode(path, UnixFileMode.UserRead | UnixFileMode.UserWrite);
            }
        }
        finally
        {
            if (File.Exists(temporary))
            {
                File.Delete(temporary);
            }
        }
    }

    private static string NormalizePathForFingerprint(string path) =>
        OperatingSystem.IsWindows() ? path.ToUpperInvariant() : path;

    private static string Sha256Hex(byte[] value) =>
        Convert.ToHexString(SHA256.HashData(value)).ToLowerInvariant();

    private static string? GetString(JsonElement root, string name) =>
        TryGetProperty(root, name, out var value) && value.ValueKind == JsonValueKind.String
            ? value.GetString()
            : null;

    private static long GetInt64(JsonElement root, string name) =>
        TryGetProperty(root, name, out var value) && value.TryGetInt64(out var result)
            ? result
            : 0;

    private static int? GetInt32(JsonElement root, string name) =>
        TryGetProperty(root, name, out var value) && value.TryGetInt32(out var result)
            ? result
            : null;

    private static bool? GetBoolean(JsonElement root, string name) =>
        TryGetProperty(root, name, out var value) && value.ValueKind is JsonValueKind.True or JsonValueKind.False
            ? value.GetBoolean()
            : null;

    private static bool HasNonNullProperty(JsonElement root, string name) =>
        TryGetProperty(root, name, out var value) && value.ValueKind is not (JsonValueKind.Null or JsonValueKind.Undefined);

    private static IReadOnlyList<string> GetObjectPropertyNames(JsonElement root, string name) =>
        TryGetProperty(root, name, out var value) && value.ValueKind == JsonValueKind.Object
            ? value.EnumerateObject().Select(property => property.Name).ToArray()
            : [];

    private static int GetObjectPropertyCount(JsonElement root, string name) =>
        TryGetProperty(root, name, out var value) && value.ValueKind == JsonValueKind.Object
            ? value.EnumerateObject().Count()
            : 0;

    private static bool TryGetProperty(JsonElement root, string name, out JsonElement value)
    {
        foreach (var property in root.EnumerateObject())
        {
            if (string.Equals(property.Name, name, StringComparison.OrdinalIgnoreCase))
            {
                value = property.Value;
                return true;
            }
        }
        value = default;
        return false;
    }

    private sealed class ReferenceAccumulator(
        IReadOnlySet<string> allowedOrigins,
        ISet<string> blockers)
    {
        private readonly Dictionary<string, ExpectedAsset> _assets = new(StringComparer.OrdinalIgnoreCase);
        private readonly Dictionary<string, string> _referenceTargets = new(StringComparer.Ordinal);

        internal IReadOnlyDictionary<string, ExpectedAsset> Assets => _assets;
        internal int IgnoredExternalCount { get; private set; }
        internal int InvalidManagedCount { get; private set; }

        internal void Add(string? url, string reference)
        {
            var location = NormalizeManagedMediaLocation(url, allowedOrigins);
            if (location.Kind == ManagedMediaLocationKind.External)
            {
                IgnoredExternalCount++;
                return;
            }
            if (location.Kind != ManagedMediaLocationKind.Managed ||
                location.AssetId is null ||
                location.StoredName is null)
            {
                InvalidManagedCount++;
                blockers.Add("database-managed-media-location-invalid");
                return;
            }

            if (_referenceTargets.TryGetValue(reference, out var existingAsset) &&
                !string.Equals(existingAsset, location.AssetId, StringComparison.OrdinalIgnoreCase))
            {
                blockers.Add("one-exact-reference-targets-multiple-assets");
                return;
            }
            _referenceTargets[reference] = location.AssetId;

            if (!_assets.TryGetValue(location.AssetId, out var asset))
            {
                asset = new ExpectedAsset(location.AssetId, location.StoredName);
                _assets[location.AssetId] = asset;
            }
            else if (!string.Equals(asset.StoredName, location.StoredName, StringComparison.OrdinalIgnoreCase))
            {
                blockers.Add("one-asset-id-has-multiple-stored-names");
                return;
            }
            asset.References.Add(reference);
        }
    }

    private sealed record ExpectedAsset(string AssetId, string StoredName)
    {
        internal HashSet<string> References { get; } = new(StringComparer.Ordinal);
    }

    private sealed record MetadataProbe(
        string Status,
        string? StoredName,
        string? State,
        int? LifecycleVersion,
        bool? LegacyPinned,
        long OwnerUserId,
        IReadOnlyList<string> ActiveReferences,
        int PendingReferenceCount,
        bool HasReservation,
        bool IsLegacy)
    {
        internal static MetadataProbe Corrupt { get; } = new(
            "corrupt",
            null,
            null,
            null,
            null,
            0,
            [],
            0,
            false,
            true);
    }

    private sealed record StorageSnapshot(
        IReadOnlyDictionary<string, List<string>> Physical,
        IReadOnlyDictionary<string, MetadataProbe> Metadata);

    private readonly record struct OutboxAudit(long LegacyCount, long ExactCount, long InvalidCount)
    {
        public static OutboxAudit operator +(OutboxAudit left, OutboxAudit right) =>
            new(
                left.LegacyCount + right.LegacyCount,
                left.ExactCount + right.ExactCount,
                left.InvalidCount + right.InvalidCount);
    }
}

internal sealed class MediaStorageExclusiveLock : IAsyncDisposable
{
    private readonly IReadOnlyList<FileStream> _streams;

    private MediaStorageExclusiveLock(IReadOnlyList<FileStream> streams)
    {
        _streams = streams;
    }

    internal static async Task<MediaStorageExclusiveLock> AcquireAsync(
        string uploadRoot,
        CancellationToken cancellationToken)
    {
        var lockRoot = Path.Combine(uploadRoot, ".metadata", ".locks");
        Directory.CreateDirectory(lockRoot);
        var streams = new List<FileStream>(256);
        var deadline = DateTimeOffset.UtcNow.AddSeconds(30);
        try
        {
            for (var value = 0; value <= byte.MaxValue; value++)
            {
                var path = Path.Combine(lockRoot, $"asset-{value:x2}.lock");
                while (true)
                {
                    cancellationToken.ThrowIfCancellationRequested();
                    try
                    {
                        streams.Add(new FileStream(
                            path,
                            FileMode.OpenOrCreate,
                            FileAccess.ReadWrite,
                            FileShare.None,
                            1,
                            FileOptions.Asynchronous | FileOptions.WriteThrough));
                        break;
                    }
                    catch (IOException) when (DateTimeOffset.UtcNow < deadline)
                    {
                        await Task.Delay(25, cancellationToken);
                    }
                    catch (IOException exception)
                    {
                        throw new TimeoutException(
                            "Could not acquire every Upload lifecycle bucket lock. A writer may still be running.",
                            exception);
                    }
                }
            }
            return new MediaStorageExclusiveLock(streams);
        }
        catch
        {
            for (var index = streams.Count - 1; index >= 0; index--)
            {
                await streams[index].DisposeAsync();
            }
            throw;
        }
    }

    public async ValueTask DisposeAsync()
    {
        for (var index = _streams.Count - 1; index >= 0; index--)
        {
            await _streams[index].DisposeAsync();
        }
    }
}
