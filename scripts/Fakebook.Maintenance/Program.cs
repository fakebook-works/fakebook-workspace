using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using Npgsql;

const string MigrationTable = "__EFMigrationsHistory";
string[] managedSchemas = ["auth", "social_graph", "recommendation", "search", "notification", "messenger", "payment"];

if (args.Length == 0)
{
    Fail("Usage: Fakebook.Maintenance <generate-jwt-keys|preflight|apply|migrate|verify|invariants|history|security-audit|verify-service-roles|rotate-owner-password|demote-owner|activate-users> [options]");
}

var command = args[0].ToLowerInvariant();
var options = Arguments.Parse(args.Skip(1).ToArray());
var environmentFile = options.Value("env-file");
LoadEnvironmentFile(environmentFile);
var workspace = FindWorkspaceRoot(AppContext.BaseDirectory);
if (command == "generate-jwt-keys")
{
    if (string.IsNullOrWhiteSpace(environmentFile))
        Fail("generate-jwt-keys requires --env-file.");
    var resolvedEnvironmentFile = Path.GetFullPath(environmentFile!);
    GenerateJwtKeys(resolvedEnvironmentFile, options.Flag("rotate"));
    Print(new
    {
        success = true,
        environmentFile = resolvedEnvironmentFile,
        rotated = options.Flag("rotate"),
        privateKeyPrinted = false
    }, options.Flag("json"));
    return;
}
var target = DatabaseTarget.FromEnvironment();
var uploadPath = NormalizeOptionalPath(options.Value("upload-path"));
var uploadTarget = options.Value("upload-target") ?? uploadPath;

await using var connection = new NpgsqlConnection(target.ConnectionString);
await connection.OpenAsync();
var identity = await ReadIdentityAsync(connection);
var fingerprint = CreateFingerprint(target, identity, managedSchemas, uploadTarget);

switch (command)
{
    case "security-audit":
    {
        var roles = new List<object>();
        await using (var roleCommand = new NpgsqlCommand(
                         """
                         SELECT rolname, rolsuper, rolcreatedb, rolcreaterole, rolcanlogin, rolbypassrls, oid = 10
                         FROM pg_roles
                         WHERE rolname = current_user OR rolname LIKE 'fakebook\_%'
                         ORDER BY rolname;
                         """,
                         connection))
        await using (var reader = await roleCommand.ExecuteReaderAsync())
        {
            while (await reader.ReadAsync())
            {
                roles.Add(new
                {
                    name = reader.GetString(0),
                    superuser = reader.GetBoolean(1),
                    createDatabase = reader.GetBoolean(2),
                    createRole = reader.GetBoolean(3),
                    canLogin = reader.GetBoolean(4),
                    bypassRowLevelSecurity = reader.GetBoolean(5),
                    bootstrapRole = reader.GetBoolean(6)
                });
            }
        }

        var schemas = new List<object>();
        await using (var schemaCommand = new NpgsqlCommand(
                         """
                         SELECT n.nspname,
                                pg_get_userbyid(n.nspowner),
                                has_schema_privilege('public', n.oid, 'USAGE'),
                                has_schema_privilege(current_user, n.oid, 'CREATE')
                         FROM pg_namespace n
                         WHERE n.nspname = ANY (@schemas) OR n.nspname = 'public'
                         ORDER BY n.nspname;
                         """,
                         connection))
        {
            schemaCommand.Parameters.AddWithValue("schemas", managedSchemas);
            await using var reader = await schemaCommand.ExecuteReaderAsync();
            while (await reader.ReadAsync())
            {
                schemas.Add(new
                {
                    name = reader.GetString(0),
                    owner = reader.GetString(1),
                    publicUsage = reader.GetBoolean(2),
                    currentUserCanCreate = reader.GetBoolean(3)
                });
            }
        }

        var extensions = new List<object>();
        await using (var extensionCommand = new NpgsqlCommand(
                         """
                         SELECT e.extname, n.nspname
                         FROM pg_extension e
                         JOIN pg_namespace n ON n.oid = e.extnamespace
                         ORDER BY e.extname;
                         """,
                         connection))
        await using (var reader = await extensionCommand.ExecuteReaderAsync())
        {
            while (await reader.ReadAsync())
            {
                extensions.Add(new { name = reader.GetString(0), schema = reader.GetString(1) });
            }
        }

        Print(new { fingerprint, identity, roles, schemas, extensions }, options.Flag("json"));
        break;
    }
    case "verify-service-roles":
    {
        var specifications = new[]
        {
            new ServiceRoleSpecification("AUTH", "fakebook_auth", "auth", false),
            new ServiceRoleSpecification("SOCIALGRAPH", "fakebook_social_graph", "social_graph", false),
            new ServiceRoleSpecification("RECOMMENDATION", "fakebook_recommendation", "recommendation", true),
            new ServiceRoleSpecification("SEARCH", "fakebook_search", "search", false),
            new ServiceRoleSpecification("NOTIFICATION", "fakebook_notification", "notification", false),
            new ServiceRoleSpecification("MESSENGER", "fakebook_messenger", "messenger", false),
            new ServiceRoleSpecification("PAYMENT", "fakebook_payment", "payment", false)
        };

        var results = new List<ServiceRoleVerification>();
        foreach (var specification in specifications)
        {
            var configuredUser = RequiredEnvironment($"{specification.EnvironmentPrefix}_DB_USER");
            var configuredPassword = RequiredEnvironment($"{specification.EnvironmentPrefix}_DB_PASSWORD");
            if (!configuredUser.Equals(specification.Role, StringComparison.Ordinal))
                Fail($"{specification.EnvironmentPrefix}_DB_USER must be '{specification.Role}'.");

            results.Add(await VerifyServiceRoleAsync(
                connection,
                target,
                specification,
                configuredPassword,
                managedSchemas));
        }

        var success = results.All(result => result.Success);
        Print(new
        {
            success,
            fingerprint,
            database = identity.Database,
            roles = results
        }, options.Flag("json"));
        if (!success) Environment.ExitCode = 2;
        break;
    }
    case "demote-owner":
    {
        if (!options.Flag("writers-stopped"))
            Fail("demote-owner requires --writers-stopped.");
        if (!string.Equals(options.Value("confirm"), fingerprint, StringComparison.OrdinalIgnoreCase))
            Fail($"Fingerprint mismatch. Current fingerprint is {fingerprint}.");
        if (!identity.User.Equals("fakebook", StringComparison.Ordinal))
            Fail("demote-owner must run as the dedicated fakebook migration owner.");

        await using (var bootstrapCommand = new NpgsqlCommand(
                         "SELECT oid = 10 FROM pg_roles WHERE rolname = current_user;",
                         connection))
        {
            if (Convert.ToBoolean(await bootstrapCommand.ExecuteScalarAsync()))
            {
                Fail(
                    "PostgreSQL does not permit removing SUPERUSER from the bootstrap role. " +
                    "Keep this credential outside runtime containers or create a separate migration owner with a cluster administrator.");
            }
        }

        await using var demotionCommand = new NpgsqlCommand(
            $"ALTER ROLE {Quote(identity.User)} NOSUPERUSER NOCREATEDB NOCREATEROLE NOBYPASSRLS NOINHERIT;",
            connection);
        await demotionCommand.ExecuteNonQueryAsync();
        Print(new
        {
            success = true,
            fingerprint,
            role = identity.User,
            superuser = false,
            createDatabase = false,
            createRole = false,
            bypassRowLevelSecurity = false,
            inherits = false
        }, options.Flag("json"));
        break;
    }
    case "rotate-owner-password":
    {
        if (!options.Flag("writers-stopped"))
            Fail("rotate-owner-password requires --writers-stopped.");
        if (!string.Equals(options.Value("confirm"), fingerprint, StringComparison.OrdinalIgnoreCase))
            Fail($"Fingerprint mismatch. Current fingerprint is {fingerprint}.");
        if (identity.User.StartsWith("fakebook_", StringComparison.Ordinal))
            Fail("A runtime service role cannot be used as the migration owner.");
        var replacement = RequiredEnvironment("NEW_DB_PASSWORD");
        if (Encoding.UTF8.GetByteCount(replacement) < 32)
            Fail("NEW_DB_PASSWORD must contain at least 32 UTF-8 bytes.");
        if (CryptographicOperations.FixedTimeEquals(
                Encoding.UTF8.GetBytes(replacement),
                Encoding.UTF8.GetBytes(target.Password)))
            Fail("NEW_DB_PASSWORD must differ from the current password.");

        await using var rotationCommand = new NpgsqlCommand(
            $"ALTER ROLE {Quote(identity.User)} PASSWORD {QuoteLiteral(replacement)};",
            connection);
        await rotationCommand.ExecuteNonQueryAsync();
        Print(new
        {
            success = true,
            fingerprint,
            role = identity.User,
            passwordPrinted = false
        }, options.Flag("json"));
        break;
    }
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
    case "migrate":
    {
        // The service migrations are plain .sql files that were documented as "run with
        // psql". psql is not installed on every workstation, and when it is missing the
        // command just fails, which looks indistinguishable from having applied cleanly.
        // This runs the same files through the Npgsql client already referenced here.
        //
        // Unrelated to the "apply" command above, which TRUNCATEs the managed schemas.
        if (!options.Flag("writers-stopped"))
            Fail("migrate requires --writers-stopped: index builds lock the tables they touch.");

        var files = options.Values("file")
            .Select(value => Path.GetFullPath(value.Trim()))
            .Where(value => value.Length > 0)
            .ToList();
        if (files.Count == 0)
        {
            // Deliberately no "apply everything" default. These are hand-applied .sql files
            // with no history table, so nothing can tell which have already run, and the
            // older ones are not re-runnable — 20260713_add_gender.sql still targets the
            // "fb" schema that a later migration renamed to "auth". Naming the files is the
            // only safe contract.
            var available = new List<string>();
            foreach (var folder in new[]
                     {
                         Path.Combine(workspace, "SocialGraphService", "SocialGraph.Api", "migrations"),
                         Path.Combine(workspace, "AuthenticationService", "Backend-Authentication", "fakebookAuth", "migrations")
                     })
            {
                if (Directory.Exists(folder)) available.AddRange(Directory.GetFiles(folder, "*.sql"));
            }
            available.Sort(StringComparer.OrdinalIgnoreCase);
            var listing = available.Count == 0
                ? "  (none found)"
                : string.Join(Environment.NewLine, available.Select(item => "  " + Path.GetRelativePath(workspace, item)));
            Fail(
                "migrate requires at least one --file. There is no migration history table, so "
                + "which files still need applying is a decision, not something to infer."
                + Environment.NewLine + "Available:" + Environment.NewLine + listing);
        }

        var applied = new List<object>();
        foreach (var file in files)
        {
            if (!File.Exists(file)) Fail($"Migration file not found: {file}");
            var sql = await File.ReadAllTextAsync(file);

            // Each file carries its own BEGIN/COMMIT, so it applies completely or not at all.
            await using var migration = new NpgsqlCommand(sql, connection) { CommandTimeout = 600 };
            try
            {
                await migration.ExecuteNonQueryAsync();
            }
            catch (PostgresException exception)
            {
                Fail($"{Path.GetFileName(file)} failed: {exception.MessageText}");
            }

            applied.Add(new { file = Path.GetFileName(file), path = file });
        }

        Print(new { success = true, database = identity.Database, applied }, options.Flag("json"));
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

static async Task<ServiceRoleVerification> VerifyServiceRoleAsync(
    NpgsqlConnection administrator,
    DatabaseTarget target,
    ServiceRoleSpecification specification,
    string password,
    string[] managedSchemas)
{
    var metadata = new RoleMetadata(false, false, false, false, false, false);
    await using (var command = new NpgsqlCommand(
                     """
                     SELECT rolcanlogin, rolsuper, rolcreatedb, rolcreaterole, rolinherit, rolbypassrls
                     FROM pg_roles
                     WHERE rolname = @role;
                     """,
                     administrator))
    {
        command.Parameters.AddWithValue("role", specification.Role);
        await using var reader = await command.ExecuteReaderAsync();
        if (await reader.ReadAsync())
        {
            metadata = new RoleMetadata(
                Exists: true,
                CanLogin: reader.GetBoolean(0),
                Superuser: reader.GetBoolean(1),
                CreateDatabase: reader.GetBoolean(2),
                CreateRole: reader.GetBoolean(3),
                Inherits: reader.GetBoolean(4),
                BypassRowLevelSecurity: reader.GetBoolean(5));
        }
    }

    var usableSchemas = new List<string>();
    var creatableSchemas = new List<string>();
    foreach (var schema in managedSchemas.Append("public"))
    {
        await using var command = new NpgsqlCommand(
            "SELECT has_schema_privilege(@role, @schema, 'USAGE'), has_schema_privilege(@role, @schema, 'CREATE');",
            administrator);
        command.Parameters.AddWithValue("role", specification.Role);
        command.Parameters.AddWithValue("schema", schema);
        await using var reader = await command.ExecuteReaderAsync();
        await reader.ReadAsync();
        if (reader.GetBoolean(0)) usableSchemas.Add(schema);
        if (reader.GetBoolean(1)) creatableSchemas.Add(schema);
    }

    var missingOwnTablePrivileges = await CountTablePrivilegeFailuresAsync(
        administrator, specification.Role, specification.Schema, expectGranted: true);
    var crossSchemaTablePrivileges = 0L;
    foreach (var schema in managedSchemas.Where(schema => schema != specification.Schema))
    {
        crossSchemaTablePrivileges += await CountTablePrivilegeFailuresAsync(
            administrator, specification.Role, schema, expectGranted: false);
    }

    var missingOwnSequencePrivileges = await CountSequencePrivilegeFailuresAsync(
        administrator, specification.Role, specification.Schema, expectGranted: true);
    var crossSchemaSequencePrivileges = 0L;
    foreach (var schema in managedSchemas.Where(schema => schema != specification.Schema))
    {
        crossSchemaSequencePrivileges += await CountSequencePrivilegeFailuresAsync(
            administrator, specification.Role, schema, expectGranted: false);
    }

    string? connectionError = null;
    string? connectedAs = null;
    try
    {
        var builder = new NpgsqlConnectionStringBuilder(target.ConnectionString)
        {
            Username = specification.Role,
            Password = password,
            SearchPath = specification.PublicUsageRequired
                ? $"{specification.Schema},public"
                : specification.Schema,
            ApplicationName = $"fakebook-role-verifier-{specification.Schema}"
        };
        await using var serviceConnection = new NpgsqlConnection(builder.ConnectionString);
        await serviceConnection.OpenAsync();
        await using var identityCommand = new NpgsqlCommand("SELECT current_user;", serviceConnection);
        connectedAs = Convert.ToString(await identityCommand.ExecuteScalarAsync());
    }
    catch (Exception exception) when (exception is NpgsqlException or TimeoutException)
    {
        connectionError = exception.Message;
    }

    var expectedUsage = new HashSet<string>(StringComparer.Ordinal)
    {
        specification.Schema
    };
    if (specification.PublicUsageRequired) expectedUsage.Add("public");

    var actualUsage = usableSchemas.ToHashSet(StringComparer.Ordinal);
    var success = metadata.Exists && metadata.CanLogin && !metadata.Superuser &&
                  !metadata.CreateDatabase && !metadata.CreateRole && !metadata.Inherits &&
                  !metadata.BypassRowLevelSecurity && actualUsage.SetEquals(expectedUsage) &&
                  creatableSchemas.Count == 0 && missingOwnTablePrivileges == 0 &&
                  crossSchemaTablePrivileges == 0 && missingOwnSequencePrivileges == 0 &&
                  crossSchemaSequencePrivileges == 0 && connectionError is null &&
                  connectedAs == specification.Role;

    return new ServiceRoleVerification(
        specification.Role,
        specification.Schema,
        success,
        connectedAs,
        connectionError,
        metadata,
        usableSchemas,
        creatableSchemas,
        missingOwnTablePrivileges,
        crossSchemaTablePrivileges,
        missingOwnSequencePrivileges,
        crossSchemaSequencePrivileges);
}

static async Task<long> CountTablePrivilegeFailuresAsync(
    NpgsqlConnection connection,
    string role,
    string schema,
    bool expectGranted)
{
    const string allPrivileges =
        "has_table_privilege(@role, quote_ident(table_schema) || '.' || quote_ident(table_name), 'SELECT') " +
        "AND has_table_privilege(@role, quote_ident(table_schema) || '.' || quote_ident(table_name), 'INSERT') " +
        "AND has_table_privilege(@role, quote_ident(table_schema) || '.' || quote_ident(table_name), 'UPDATE') " +
        "AND has_table_privilege(@role, quote_ident(table_schema) || '.' || quote_ident(table_name), 'DELETE')";
    const string anyPrivilege =
        "has_table_privilege(@role, quote_ident(table_schema) || '.' || quote_ident(table_name), 'SELECT') " +
        "OR has_table_privilege(@role, quote_ident(table_schema) || '.' || quote_ident(table_name), 'INSERT') " +
        "OR has_table_privilege(@role, quote_ident(table_schema) || '.' || quote_ident(table_name), 'UPDATE') " +
        "OR has_table_privilege(@role, quote_ident(table_schema) || '.' || quote_ident(table_name), 'DELETE')";
    var predicate = expectGranted ? $"NOT ({allPrivileges})" : $"({anyPrivilege})";
    await using var command = new NpgsqlCommand(
        $"SELECT count(*) FROM information_schema.tables WHERE table_schema = @schema AND table_type = 'BASE TABLE' AND {predicate};",
        connection);
    command.Parameters.AddWithValue("role", role);
    command.Parameters.AddWithValue("schema", schema);
    return Convert.ToInt64(await command.ExecuteScalarAsync() ?? 0L);
}

static async Task<long> CountSequencePrivilegeFailuresAsync(
    NpgsqlConnection connection,
    string role,
    string schema,
    bool expectGranted)
{
    const string allPrivileges =
        "has_sequence_privilege(@role, quote_ident(sequence_schema) || '.' || quote_ident(sequence_name), 'USAGE') " +
        "AND has_sequence_privilege(@role, quote_ident(sequence_schema) || '.' || quote_ident(sequence_name), 'SELECT')";
    const string anyPrivilege =
        "has_sequence_privilege(@role, quote_ident(sequence_schema) || '.' || quote_ident(sequence_name), 'USAGE') " +
        "OR has_sequence_privilege(@role, quote_ident(sequence_schema) || '.' || quote_ident(sequence_name), 'SELECT')";
    var predicate = expectGranted ? $"NOT ({allPrivileges})" : $"({anyPrivilege})";
    await using var command = new NpgsqlCommand(
        $"SELECT count(*) FROM information_schema.sequences WHERE sequence_schema = @schema AND {predicate};",
        connection);
    command.Parameters.AddWithValue("role", role);
    command.Parameters.AddWithValue("schema", schema);
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
static string QuoteLiteral(string value) => $"'{value.Replace("'", "''")}'";
static string RequiredEnvironment(string name) =>
    Environment.GetEnvironmentVariable(name) is { Length: > 0 } value
        ? value
        : throw new InvalidOperationException($"{name} is required.");

static void GenerateJwtKeys(string environmentFile, bool rotate)
{
    if (!File.Exists(environmentFile)) Fail($"Environment file not found: {environmentFile}");
    var lines = File.ReadAllLines(environmentFile).ToList();
    var values = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
    foreach (var raw in lines)
    {
        var line = raw.Trim();
        if (line.Length == 0 || line.StartsWith('#')) continue;
        var separator = line.IndexOf('=');
        if (separator <= 0) continue;
        values[line[..separator].Trim()] = line[(separator + 1)..].Trim().Trim('"');
    }

    values.TryGetValue("JWT_PRIVATE_KEY_BASE64", out var privateKey);
    values.TryGetValue("JWT_PUBLIC_KEY_BASE64", out var publicKey);
    values.TryGetValue("JWT_KEY_ID", out var keyId);
    var hasExisting = !string.IsNullOrWhiteSpace(privateKey) &&
                      !string.IsNullOrWhiteSpace(publicKey) &&
                      !string.IsNullOrWhiteSpace(keyId);
    if (hasExisting && !rotate)
    {
        if (!IsValidJwtKeyPair(privateKey!, publicKey!))
            Fail("Existing JWT RSA material is invalid or mismatched; rerun with --rotate.");
        return;
    }

    using var rsa = RSA.Create(3072);
    privateKey = Convert.ToBase64String(rsa.ExportPkcs8PrivateKey());
    publicKey = Convert.ToBase64String(rsa.ExportSubjectPublicKeyInfo());
    var keyFingerprint = Convert.ToHexString(SHA256.HashData(Convert.FromBase64String(publicKey)))[..12].ToLowerInvariant();
    keyId = $"fakebook-rs256-{DateTime.UtcNow:yyyyMMdd}-{keyFingerprint}";

    var updates = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase)
    {
        ["JWT_PRIVATE_KEY_BASE64"] = privateKey,
        ["JWT_PUBLIC_KEY_BASE64"] = publicKey,
        ["JWT_KEY_ID"] = keyId
    };
    if (!values.ContainsKey("JWT_LEGACY_SIGNING_KEY")) updates["JWT_LEGACY_SIGNING_KEY"] = string.Empty;

    var seen = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
    for (var index = 0; index < lines.Count; index++)
    {
        var separator = lines[index].IndexOf('=');
        if (separator <= 0) continue;
        var name = lines[index][..separator].Trim();
        if (!updates.TryGetValue(name, out var value)) continue;
        lines[index] = $"{name}={value}";
        seen.Add(name);
    }
    foreach (var update in updates.Where(update => !seen.Contains(update.Key)))
        lines.Add($"{update.Key}={update.Value}");

    var temporaryFile = environmentFile + $".{Guid.NewGuid():N}.tmp";
    try
    {
        File.WriteAllLines(temporaryFile, lines, new UTF8Encoding(false));
        File.Move(temporaryFile, environmentFile, overwrite: true);
    }
    finally
    {
        if (File.Exists(temporaryFile)) File.Delete(temporaryFile);
    }
}

static bool IsValidJwtKeyPair(string privateKeyBase64, string publicKeyBase64)
{
    try
    {
        using var privateRsa = RSA.Create();
        privateRsa.ImportPkcs8PrivateKey(Convert.FromBase64String(privateKeyBase64), out var privateBytes);
        using var publicRsa = RSA.Create();
        publicRsa.ImportSubjectPublicKeyInfo(Convert.FromBase64String(publicKeyBase64), out var publicBytes);
        if (privateBytes == 0 || publicBytes == 0 || privateRsa.KeySize < 2048 || publicRsa.KeySize < 2048)
            return false;
        var challenge = RandomNumberGenerator.GetBytes(32);
        var signature = privateRsa.SignData(challenge, HashAlgorithmName.SHA256, RSASignaturePadding.Pkcs1);
        return publicRsa.VerifyData(challenge, signature, HashAlgorithmName.SHA256, RSASignaturePadding.Pkcs1);
    }
    catch (Exception exception) when (exception is FormatException or CryptographicException)
    {
        return false;
    }
}

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
sealed record ServiceRoleSpecification(string EnvironmentPrefix, string Role, string Schema, bool PublicUsageRequired);
sealed record RoleMetadata(
    bool Exists,
    bool CanLogin,
    bool Superuser,
    bool CreateDatabase,
    bool CreateRole,
    bool Inherits,
    bool BypassRowLevelSecurity)
{
    public RoleMetadata(bool exists, bool superuser, bool createDatabase, bool createRole, bool inherits, bool bypassRowLevelSecurity)
        : this(exists, false, superuser, createDatabase, createRole, inherits, bypassRowLevelSecurity)
    {
    }
}
sealed record ServiceRoleVerification(
    string Role,
    string Schema,
    bool Success,
    string? ConnectedAs,
    string? ConnectionError,
    RoleMetadata Metadata,
    IReadOnlyList<string> UsableSchemas,
    IReadOnlyList<string> CreatableSchemas,
    long MissingOwnTablePrivileges,
    long CrossSchemaTablePrivileges,
    long MissingOwnSequencePrivileges,
    long CrossSchemaSequencePrivileges);

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
