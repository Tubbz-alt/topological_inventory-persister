require "inventory_refresh"
require "manageiq-messaging"
require "topological_inventory/persister/logging"
require "topological_inventory/persister/workflow"
require "topological_inventory/schema"

module TopologicalInventory
  module Persister
    class Worker
      include Logging

      def initialize(messaging_client_opts = {})
        self.messaging_client_opts = default_messaging_opts.merge(messaging_client_opts)

        InventoryRefresh.logger = logger
      end

      def run
        # Open a connection to the messaging service
        self.client = ManageIQ::Messaging::Client.open(messaging_client_opts)

        logger.info("Topological Inventory Persister started...")

        # Wait for messages to be processed
        # TODO(lsmola) do: client.subscribe_messages(queue_opts.merge(:max_bytes => 500000))
        # Once this is merged and released: https://github.com/ManageIQ/manageiq-messaging/pull/35
        client.subscribe_messages(queue_opts) do |messages|
          messages.each { |msg| process_message(client, msg) }
        end
      ensure
        client&.close
      end

      def stop
        client&.close
        self.client = nil
      end

      private

      attr_accessor :messaging_client_opts, :client

      def process_message(client, msg)
        TopologicalInventory::Persister::Workflow.new(load_persister(msg.payload), client, msg.payload).execute!
      rescue => e
        logger.error(e.message)
        logger.error(e.backtrace.join("\n"))
        nil
      end

      def load_persister(payload)
        source = Source.find_by(:uid => payload["source"])
        raise "Couldn't find source with uid #{payload["source"]}" if source.nil?

        schema_name  = payload.dig("schema", "name")
        schema_klass = schema_klass_name(schema_name).safe_constantize
        raise "Invalid schema #{schema_name}" if schema_klass.nil?

        schema_klass.from_hash(payload, source)
      end

      def schema_klass_name(name)
        "TopologicalInventory::Schema::#{name}"
      end

      def queue_opts
        {
          :service => "platform.topological-inventory.persister",
        }
      end

      def default_messaging_opts
        {
          :protocol   => :Kafka,
          :client_ref => "persister-worker",
          :group_ref  => "persister-worker",
        }
      end
    end
  end
end
