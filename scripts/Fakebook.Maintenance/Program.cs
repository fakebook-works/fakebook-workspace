using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using Npgsql;

const string MigrationTable = "__EFMigrationsHistory";
string[] managedSchemas = ["auth", "social_graph", "recommendation", "search", "notification", "messenger", "payment"];

if (args.Length == 0)
{
    Fail("Usage: Fakebook.Maintenance <preflight|apply|verify|invariants|history|activate-users> [options]");
}

var command = args[0].ToLowerInvariant();
var options = Arguments.Parse(args.Skip(1).ToArray());
LoadEnvironmentFile(options.Value("env-file"));
var target = DatabaseTarget.FromEnvironment();
var uploadPath = NormalizeOptionalPath(options.Value("upload-path"));
var uploadTarget = options.Value("upload-target") ?? uploadPath;
var workspace = FindWorkspaceRoot(AppContext.BaseDirectory);

await using var connection = new NpgsqlConnection(target.ConnectionString);
await connection.OpenAsync();
var identity = await ReadIdentityAsync(connection);
var fingerprint = CreateFingerprint(target, identity, managedSchemas, uploadTarget);

switch (command)
{
    case "preflight":
    {
        var tables = await DiscoverTablesAsync(connection, managedSchemas);
        var counts = await CountRowsAsync(connection, tables);
        Print(new
        {
            fingerprint,
            configuredHost = target.Host,
            target.Port,
            database = identity.Database,
            databaseUser = identity.User,
            serverAddress = identity.ServerAddress,
            schemas = managedSchemas,
            tables = counts.Select(item => new { schema = item.Table.Schema, table = item.Table.Name, rows = item.Rows }),
            totalRows = counts.Sum(item => item.Rows),
            uploadPath,
            uploadTarget,
            uploadEntries = CountUploadEntries(uploadPath),
            isRemote = !IsLocalDevelopmentTarget(target.Host, identity.ServerAddress)
        }, options.Flag("json"));
        break;
    }
    case "verify":
    {
        var tables = await DiscoverTablesAsync(connection, managedSchemas);
        var counts = await CountRowsAsync(connection, tables);
        var remaining = counts.Where(item => item.Rows != 0).ToArray();
        var migrationTables = await DiscoverMigrationTablesAsync(connection, managedSchemas);
        Print(new
        {
            success = remaining.Length == 0,
            fingerprint,
            remaining = remaining.Select(item => new { schema = item.Table.Schema, table = item.Table.Name, rows = item.Rows }),
            preservedMigrationTables = migrationTables.Select(item => new { schema = item.Schema, table = item.Name }),
            uploadEntries = CountUploadEntries(uploadPath)
        }, options.Flag("json"));
        if (remaining.Length != 0) Environment.ExitCode = 2;
        break;
    }
    case "invariants":
    {
        var invalidAssociations = await ScalarAsync(connection,
            "SELECT count(*) FROM social_graph.associations WHERE atype < 0 OR atype > 29;");
        var orphanMedia = await ScalarAsync(connection,
            """
            SELECT count(*)
            FROM social_graph.objects AS media
            WHERE media.otype = 7
              AND NOT EXISTS (
                  SELECT 1 FROM social_graph.associations AS link
                  WHERE link.atype = 28 AND link.id2 = media.id
              );
            """);
        var adminsWithoutMembership = await ScalarAsync(connection,
            """
            SELECT count(*)
            FROM social_graph.associations AS admin
            WHERE admin.atype = 15
              AND NOT EXISTS (
                  SELECT 1 FROM social_graph.associations AS member
                  WHERE member.atype = 13 AND member.id1 = admin.id1 AND member.id2 = admin.id2
              );
            """);
        var deadLetters = await ScalarAsync(connection,
            "SELECT count(*) FROM social_graph.integration_outbox WHERE status = 3;");
        var duplicateDirectPairs = await ScalarAsync(connection,
            """
            SELECT count(*)
            FROM (
                SELECT direct_user_low_id, direct_user_high_id
                FROM messenger.conversations
                WHERE type = 'Direct'
                GROUP BY direct_user_low_id, direct_user_high_id
                HAVING count(*) > 1
            ) AS duplicates;
            """);
        var success = invalidAssociations == 0 && orphanMedia == 0 && adminsWithoutMembership == 0 &&
                      deadLetters == 0 && duplicateDirectPairs == 0;
        Print(new
        {
            success,
            invalidAssociations,
            orphanMedia,
            adminsWithoutMembership,
            deadLetters,
            duplicateDirectPairs
        }, options.Flag("json"));
        if (!success) Environment.ExitCode = 2;
        break;
    }
    case "history":
    {
        await using var historyCommand = new NpgsqlCommand(
            "SELECT table_schema, table_name FROM information_schema.tables WHERE lower(table_name) = lower('__EFMigrationsHistory') ORDER BY table_schema;",
            connection);
        var history = new List<DbTable>();
        await using var historyReader = await historyCommand.ExecuteReaderAsync();
        while (await historyReader.ReadAsync()) history.Add(new DbTable(historyReader.GetString(0), historyReader.GetString(1)));
        Print(new { history }, options.Flag("json"));
        break;
    }
    case "apply":
    {
        var environment = options.Value("environment") ?? string.Empty;
        if (!environment.Equals("Development", StringComparison.OrdinalIgnoreCase))
            Fail("Reset apply is allowed only with --environment Development.");
        if (!options.Flag("writers-stopped"))
            Fail("Reset apply requires --writers-stopped.");
        if (!string.Equals(options.Value("confirm"), fingerprint, StringComparison.OrdinalIgnoreCase))
            Fail($"Fingerprint mismatch. Current fingerprint is {fingerprint}.");
        if (!IsLocalDevelopmentTarget(target.Host, identity.ServerAddress) && !options.Flag("allow-remote-development-database"))
            Fail("The database is not local/compose-local. Pass --allow-remote-development-database only after verifying this Development target.");
        if (uploadPath is null && !options.Flag("skip-upload-cleanup"))
            Fail("Apply requires --upload-path or the explicit --skip-upload-cleanup acknowledgement.");

        var tables = await DiscoverTablesAsync(connection, managedSchemas);
        await using (var transaction = await connection.BeginTransactionAsync())
        {
            if (tables.Count > 0)
            {
                var identifiers = string.Join(", ", tables.Select(table => $"{Quote(table.Schema)}.{Quote(table.Name)}"));
                await using var truncate = new NpgsqlCommand($"TRUNCATE TABLE {identifiers} RESTART IDENTITY CASCADE;", connection, transaction);
                await truncate.ExecuteNonQueryAsync();
            }
            await transaction.CommitAsync();
        }

        var remaining = (await CountRowsAsync(connection, tables)).Where(item => item.Rows != 0).ToArray();
        if (remaining.Length != 0)
            Fail("Database verification failed after TRUNCATE; upload storage was not touched.");

        var deletedUploadEntries = uploadPath is null ? 0 : CleanUploadDirectory(uploadPath, workspace);
        Print(new
        {
            success = true,
            fingerprint,
            truncatedTables = tables.Count,
            deletedUploadEntries,
            preservedMigrationTables = await DiscoverMigrationTablesAsync(connection, managedSchemas)
        }, options.Flag("json"));
        break;
    }
    case "activate-users":
    {
        if (!options.Flag("development-seed"))
            Fail("activate-users is restricted to --development-seed.");
        if (!string.Equals(options.Value("environment"), "Development", StringComparison.OrdinalIgnoreCase))
            Fail("activate-users is allowed only with --environment Development.");
        if (!string.Equals(options.Value("confirm"), fingerprint, StringComparison.OrdinalIgnoreCase))
            Fail($"Fingerprint mismatch. Current fingerprint is {fingerprint}.");
        if (!IsLocalDevelopmentTarget(target.Host, identity.ServerAddress) && !options.Flag("allow-remote-development-database"))
            Fail("Remote demo activation requires --allow-remote-development-database.");
        var emails = options.Values("email")
            .Select(value => value.Trim().ToLowerInvariant())
            .Where(value => value.Length > 0)
            .Distinct(StringComparer.OrdinalIgnoreCase)
            .ToArray();
        if (emails.Length == 0) Fail("activate-users requires at least one --email value.");
        await using var update = new NpgsqlCommand(
            "UPDATE auth.id_user SET status = 1, updated_at = CURRENT_TIMESTAMP WHERE lower(email) = ANY (@emails);",
            connection);
        update.Parameters.AddWithValue("emails", emails);
        var updated = await update.ExecuteNonQueryAsync();
        if (updated != emails.Length) Fail($"Expected to activate {emails.Length} demo users but updated {updated}.");
        Print(new { success = true, activated = updated }, options.Flag("json"));
        break;
    }
    default:
        Fail($"Unknown command '{command}'.");
        break;
}

static async Task<DatabaseIdentity> ReadIdentityAsync(NpgsqlConnection connection)
{
    await using var command = new NpgsqlCommand(
        "SELECT current_database(), current_user, COALESCE(inet_server_addr()::text, 'local');",
        connection);
    await using var reader = await command.ExecuteReaderAsync();
    await reader.ReadAsync();
    return new DatabaseIdentity(reader.GetString(0), reader.GetString(1), reader.GetString(2));
}

static async Task<List<DbTable>> DiscoverTablesAsync(NpgsqlConnection connection, string[] schemas)
{
    await using var command = new NpgsqlCommand(
        """
        SELECT table_schema, table_name
        FROM information_schema.tables
        WHERE table_type = 'BASE TABLE'
          AND table_schema = ANY (@schemas)
          AND lower(table_name) <> lower(@migration_table)
        ORDER BY table_schema, table_name;
        """,
        connection);
    command.Parameters.AddWithValue("schemas", schemas);
    command.Parameters.AddWithValue("migration_table", MigrationTable);
    var tables = new List<DbTable>();
    await using var reader = await command.ExecuteReaderAsync();
    while (await reader.ReadAsync()) tables.Add(new DbTable(reader.GetString(0), reader.GetString(1)));
    return tables;
}

static async Task<List<DbTable>> DiscoverMigrationTablesAsync(NpgsqlConnection connection, string[] schemas)
{
    await using var command = new NpgsqlCommand(
        """
        SELECT table_schema, table_name
        FROM information_schema.tables
        WHERE table_type = 'BASE TABLE'
          AND table_schema = ANY (@schemas)
          AND lower(table_name) = lower(@migration_table)
        ORDER BY table_schema;
        """,
        connection);
    command.Parameters.AddWithValue("schemas", schemas);
    command.Parameters.AddWithValue("migration_table", MigrationTable);
    var tables = new List<DbTable>();
    await using var reader = await command.ExecuteReaderAsync();
    while (await reader.ReadAsync()) tables.Add(new DbTable(reader.GetString(0), reader.GetString(1)));
    return tables;
}

static async Task<List<TableCount>> CountRowsAsync(NpgsqlConnection connection, IEnumerable<DbTable> tables)
{
    var result = new List<TableCount>();
    foreach (var table in tables)
    {
        await using var command = new NpgsqlCommand($"SELECT count(*) FROM {Quote(table.Schema)}.{Quote(table.Name)};", connection);
        result.Add(new TableCount(table, (long)(await command.ExecuteScalarAsync() ?? 0L)));
    }
    return result;
}

static async Task<long> ScalarAsync(NpgsqlConnection connection, string sql)
{
    await using var command = new NpgsqlCommand(sql, connection);
    return Convert.ToInt64(await command.ExecuteScalarAsync() ?? 0L);
}

static int CleanUploadDirectory(string path, string workspace)
{
    var fullPath = Path.GetFullPath(path);
    var root = Path.GetPathRoot(fullPath);
    if (string.IsNullOrWhiteSpace(root) || fullPath.TrimEnd(Path.DirectorySeparatorChar).Equals(root.TrimEnd(Path.DirectorySeparatorChar), StringComparison.OrdinalIgnoreCase))
        Fail("Upload cleanup refused a filesystem root.");
    var relative = Path.GetRelativePath(workspace, fullPath);
    if (relative == ".." || relative.StartsWith($"..{Path.DirectorySeparatorChar}", StringComparison.Ordinal))
        Fail("Upload cleanup path must stay inside the Fakebook workspace.");
    if (!Directory.Exists(fullPath)) return 0;
    var info = new DirectoryInfo(fullPath);
    if (info.Attributes.HasFlag(FileAttributes.ReparsePoint)) Fail("Upload cleanup refused a reparse-point directory.");

    var deleted = 0;
    foreach (var entry in Directory.EnumerateFileSystemEntries(fullPath))
    {
        if (Path.GetFileName(entry).Equals(".gitkeep", StringComparison.OrdinalIgnoreCase)) continue;
        if (Directory.Exists(entry)) Directory.Delete(entry, recursive: true); else File.Delete(entry);
        deleted++;
    }
    return deleted;
}

static int? CountUploadEntries(string? path) =>
    path is null || !Directory.Exists(path)
        ? null
        : Directory.EnumerateFileSystemEntries(path, "*", SearchOption.AllDirectories).Count();

static string CreateFingerprint(DatabaseTarget target, DatabaseIdentity identity, string[] schemas, string? uploadTarget)
{
    var canonical = string.Join('|',
        target.Host.ToLowerInvariant(),
        target.Port,
        identity.Database.ToLowerInvariant(),
        identity.User.ToLowerInvariant(),
        identity.ServerAddress.ToLowerInvariant(),
        string.Join(',', schemas.OrderBy(value => value, StringComparer.Ordinal)),
        uploadTarget?.ToLowerInvariant() ?? "no-upload-target");
    return Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(canonical)))[..12];
}

static bool IsLocalDevelopmentTarget(string host, string serverAddress)
{
    var localNames = new HashSet<string>(StringComparer.OrdinalIgnoreCase)
    {
        "localhost", "127.0.0.1", "::1", "postgres", "db", "database", "local"
    };
    return localNames.Contains(host) && (localNames.Contains(serverAddress) || serverAddress.StartsWith("127.", StringComparison.Ordinal));
}

static string? NormalizeOptionalPath(string? value) => string.IsNullOrWhiteSpace(value) ? null : Path.GetFullPath(value);
static string Quote(string identifier) => $"\"{identifier.Replace("\"", "\"\"")}\"";

static void LoadEnvironmentFile(string? path)
{
    if (string.IsNullOrWhiteSpace(path) || !File.Exists(path)) return;
    foreach (var raw in File.ReadLines(path))
    {
        var line = raw.Trim();
        if (line.Length == 0 || line.StartsWith('#')) continue;
        var separator = line.IndexOf('=');
        if (separator <= 0) continue;
        var key = line[..separator].Trim();
        var value = line[(separator + 1)..].Trim().Trim('"');
        if (string.IsNullOrWhiteSpace(Environment.GetEnvironmentVariable(key)))
            Environment.SetEnvironmentVariable(key, value);
    }
}

static string FindWorkspaceRoot(string start)
{
    var current = new DirectoryInfo(start);
    while (current is not null)
    {
        if (File.Exists(Path.Combine(current.FullName, "docker-compose.yml"))) return current.FullName;
        current = current.Parent;
    }
    Fail("Could not locate the Fakebook workspace root.");
    return string.Empty;
}

static void Print(object value, bool json)
{
    if (json)
    {
        Console.WriteLine(JsonSerializer.Serialize(value));
        return;
    }
    Console.WriteLine(JsonSerializer.Serialize(value, new JsonSerializerOptions { WriteIndented = true }));
}

static void Fail(string message)
{
    Console.Error.WriteLine(message);
    Environment.Exit(1);
}

sealed record DatabaseTarget(string Host, int Port, string Database, string User, string Password)
{
    public string ConnectionString => new NpgsqlConnectionStringBuilder
    {
        Host = Host,
        Port = Port,
        Database = Database,
        Username = User,
        Password = Password,
        Timeout = 10,
        CommandTimeout = 120,
        ApplicationName = "fakebook-maintenance"
    }.ConnectionString;

    public static DatabaseTarget FromEnvironment() => new(
        Required("DB_HOST"),
        int.TryParse(Required("DB_PORT"), out var port) ? port : throw new InvalidOperationException("DB_PORT is invalid."),
        Required("DB_NAME"),
        Required("DB_USER"),
        Required("DB_PASSWORD"));

    private static string Required(string name) =>
        Environment.GetEnvironmentVariable(name) is { Length: > 0 } value
            ? value
            : throw new InvalidOperationException($"{name} is required.");
}

sealed record DatabaseIdentity(string Database, string User, string ServerAddress);
sealed record DbTable(string Schema, string Name);
sealed record TableCount(DbTable Table, long Rows);

sealed class Arguments
{
    private readonly Dictionary<string, List<string>> _values = new(StringComparer.OrdinalIgnoreCase);

    public static Arguments Parse(string[] args)
    {
        var parsed = new Arguments();
        for (var index = 0; index < args.Length; index++)
        {
            var token = args[index];
            if (!token.StartsWith("--", StringComparison.Ordinal))
                throw new InvalidOperationException($"Invalid option '{token}'.");
            var key = token[2..];
            var value = index + 1 < args.Length && !args[index + 1].StartsWith("--", StringComparison.Ordinal)
                ? args[++index]
                : "true";
            if (!parsed._values.TryGetValue(key, out var values)) parsed._values[key] = values = [];
            values.Add(value);
        }
        return parsed;
    }

    public string? Value(string key) => _values.TryGetValue(key, out var values) ? values[^1] : null;
    public IReadOnlyList<string> Values(string key) => _values.TryGetValue(key, out var values) ? values : [];
    public bool Flag(string key) => Value(key)?.Equals("true", StringComparison.OrdinalIgnoreCase) == true;
}
