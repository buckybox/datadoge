require "datadoge/version"
require "gem_config"
require "statsd"

module Datadoge
  include GemConfig::Base

  with_configuration do
    has :environments, classes: Array, default: ["production"]
    has :prefix, classes: [Symbol, String], default: "rails"
    has :tags, classes: Array, default: []
  end

  class Railtie < Rails::Railtie
    initializer "datadoge.configure_rails_initialization" do |_app|
      $statsd = Statsd.new

      ActiveSupport::Notifications.subscribe("process_action.action_controller") do |*args|
        event = ActiveSupport::Notifications::Event.new(*args)
        payload = event.payload

        controller = "controller:#{payload.fetch(:controller).underscore}"
        action = "action:#{payload.fetch(:action)}"
        controller_action = "controller_action:#{payload.fetch(:controller).underscore}_#{payload.fetch(:action)}"
        format = "format:#{payload.fetch(:format, 'all')}"
        format = "format:all" if format == "format:*/*"
        tags = [controller, action, controller_action, format] + Datadoge.configuration.tags

        ActiveSupport::Notifications.instrument "datadoge", action: :timing, tags: tags, measurement: "request.duration", value: event.duration

        if (db_runtime = payload[:db_runtime])
          ActiveSupport::Notifications.instrument "datadoge", action: :timing, tags: tags, measurement: "request.db_runtime", value: db_runtime
        end

        if (view_runtime = payload[:view_runtime])
          ActiveSupport::Notifications.instrument "datadoge", action: :timing, tags: tags, measurement: "request.view_runtime", value: view_runtime
        end

        method_path = "#{payload.fetch(:method)}_#{payload.fetch(:path)}"
        ActiveSupport::Notifications.instrument "datadoge", action: :increment, tags: tags, measurement: "request.method_path.#{method_path}"

        status = payload.fetch(:status, 500)
        ActiveSupport::Notifications.instrument "datadoge", action: :increment, tags: tags, measurement: "request.status.#{status}"
      end

      ActiveSupport::Notifications.subscribe("deliver.action_mailer") do
        tags = Datadoge.configuration.tags

        ActiveSupport::Notifications.instrument "datadoge", action: :increment, tags: tags, measurement: "mailer.deliver"
      end

      ActiveSupport::Notifications.subscribe("datadoge") do |_name, _started, _finished, _unique_id, data|
        send_event_to_statsd(data) if Datadoge.configuration.environments.include?(Rails.env)
      end

      def send_event_to_statsd(data)
        measurement = data.fetch(:measurement)
        key_name = "#{Datadoge.configuration.prefix}.#{measurement}"
        tags = data.fetch(:tags)
        action = data.fetch(:action)

        if action == :increment
          $statsd.increment key_name, tags: tags
        else
          value = data.fetch(:value)
          $statsd.histogram key_name, value, tags: tags
        end
      end
    end
  end
end
