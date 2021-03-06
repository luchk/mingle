#  Copyright 2020 ThoughtWorks, Inc.
#  
#  This program is free software: you can redistribute it and/or modify
#  it under the terms of the GNU Affero General Public License as
#  published by the Free Software Foundation, either version 3 of the
#  License, or (at your option) any later version.
#  
#  This program is distributed in the hope that it will be useful,
#  but WITHOUT ANY WARRANTY; without even the implied warranty of
#  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
#  GNU Affero General Public License for more details.
#  
#  You should have received a copy of the GNU Affero General Public License
#  along with this program.  If not, see <https://www.gnu.org/licenses/agpl-3.0.txt>.

class Database
  @@lock = Mutex.new

  class << self
    def need_migration?
      from_files = migration_versions
      from_db = migration_versions_from_database
      (from_files != from_db).tap do |need_to_migrate|
        if need_to_migrate
          need_migrate = from_files - from_db
          if need_migrate.any?
            logger.info("Need install: Migration versions: #{need_migrate.inspect}")
          end
          missing_migration_files = from_db - from_files
          if missing_migration_files.any?
            logger.error("Degraded installer? Missing migration file for versions: #{missing_migration_files.inspect}")
          end
        end
      end
    end

    def newer_than_installer?
      current_migration_version > last_migration_version
    end

    def need_config?
      unless ActiveRecord::Base.connection.active?
        logger.info("Need install: not connected to database")
        return true
      end
    rescue ActiveRecordPartitioning::NoActiveConnectionPoolError
      return true
    rescue ActiveRecord::ConnectionTimeoutError => e
      logger.error("Database Connection Timed Out #{e}:\n#{e.backtrace.join("\n")}") if defined?(logger)
      raise e
    rescue => e
      logger.error("Error during checking db connection availablility #{e}:\n#{e.backtrace.join("\n")}") if defined?(logger)
      return true
    end

    def migrate
      return unless need_migration?
      @@lock.synchronize do
        if need_migration?
          begin
            ActiveRecord::Migrator.migrate(File.join(Rails.root, 'db', 'migrate'))
          rescue Exception => e
            logger.error {"Migration failed"}
            logger.error { e }
            raise e
          end
        end
        Install::PluginMigrations.new.do_migration
      end
    end

    def is_mysql?
      raise DatabaseVendorDetectionError.new('Unable to determine whether database is MySQL.') unless ActiveRecord::Base.configurations.kind_of?(Hash)
      return false if (!ActiveRecord::Base.configurations['production'])
      /mysql/ =~ ActiveRecord::Base.configurations['production']['driver']
    rescue => e
      logger.info("MySQL detection: #{e}")
      raise e
    end

    private
    def migration_versions_from_database
      sm_table = ActiveRecord::Migrator.schema_migrations_table_name
      if ActiveRecord::Base.connection.table_exists?(sm_table)
        ActiveRecord::Migrator.get_all_versions
      end || []
    end

    def current_migration_version
      ActiveRecord::Migrator.current_version rescue 0
    end

    def last_migration_version
      migration_versions.last
    end

    def migration_versions
      @@migration_versions ||= (Dir[File.join(Rails.root, 'db', 'migrate', '*.rb')] + plugin_migration_files).collect do |f|
        if File.basename(f) =~ /^(\d*)_/
          $1.to_i
        end
      end.compact.sort
    end

    def plugin_migration_files
      Dir[File.join(Rails.root, 'vendor', 'plugins', '*', 'db', 'migrate', '*.rb')]
    end

    def reset_last_migration_version
      @@migration_versions = nil
    end

    def logger
      Rails.logger
    end
  end
end
