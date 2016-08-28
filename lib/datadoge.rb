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

        controller = payload.fetch(:controller).underscore
        action = payload.fetch(:action)
        controller_action = "#{controller}.#{action}"
        method = payload.fetch(:method)
        format = payload[:format] || "all"
        format = "all" if format == "*/*"
        status = payload[:status].to_s

        tags = Datadoge.configuration.tags + [
          "controller:#{controller}",
          "action:#{action}",
          "controller_action:#{controller_action}",
          "method:#{method}",
          "format:#{format}"
        ]
        tags << "status:#{status}" if status.present?

        ActiveSupport::Notifications.instrument "datadoge", action: :increment, tags: tags, measurement: "request.total"
        ActiveSupport::Notifications.instrument "datadoge", action: :histogram, tags: tags, measurement: "request.duration", value: event.duration
        ActiveSupport::Notifications.instrument "datadoge", action: :increment, tags: tags, measurement: "request.slow" if event.duration > 200.0
        ActiveSupport::Notifications.instrument "datadoge", action: :increment, tags: tags, measurement: "request.method.#{method}"

        if status.present?
          ActiveSupport::Notifications.instrument "datadoge", action: :increment, tags: tags, measurement: "request.status.#{status}"
          ActiveSupport::Notifications.instrument "datadoge", action: :increment, tags: tags, measurement: "request.status.#{status[0]}xx"
          ActiveSupport::Notifications.instrument "datadoge", action: :histogram, tags: tags, measurement: "request.status.#{status}.duration", value: event.duration
          ActiveSupport::Notifications.instrument "datadoge", action: :histogram, tags: tags, measurement: "request.status.#{status[0]}xx.duration", value: event.duration
        end

        if payload[:exception]
          ActiveSupport::Notifications.instrument "datadoge", action: :increment, tags: tags, measurement: "request.exception"
        else
          ActiveSupport::Notifications.instrument "datadoge", action: :histogram, tags: tags, measurement: "request.db_runtime", value: payload[:db_runtime] || 0
          ActiveSupport::Notifications.instrument "datadoge", action: :histogram, tags: tags, measurement: "request.view_runtime", value: payload[:view_runtime] || 0
        end
      end

      %w(read generate fetch_hit write delete).each do |metric|
        ActiveSupport::Notifications.subscribe "cache_#{metric}.active_support" do |*args|
          event = ActiveSupport::Notifications::Event.new(*args)

          tags = Datadoge.configuration.tags

          ActiveSupport::Notifications.instrument "datadoge", action: :increment, tags: tags, measurement: "cache.total"
          ActiveSupport::Notifications.instrument "datadoge", action: :increment, tags: tags, measurement: "cache.#{metric}"
          ActiveSupport::Notifications.instrument "datadoge", action: :histogram, tags: tags, measurement: "cache.#{metric}.duration", value: event.duration
        end
      end

      ActiveSupport::Notifications.subscribe("deliver.action_mailer") do
        tags = Datadoge.configuration.tags

        ActiveSupport::Notifications.instrument "datadoge", action: :increment, tags: tags, measurement: "mailer.deliver.total"
      end

      ActiveSupport::Notifications.subscribe("sql.active_record") do |*args|
        event = ActiveSupport::Notifications::Event.new(*args)
        payload = event.payload

        query = payload.fetch(:sql).strip
        command = query.match(/\A(\w+) /)[1]

        tags = Datadoge.configuration.tags

        ActiveSupport::Notifications.instrument "datadoge", action: :increment, tags: tags, measurement: "sql.total"
        ActiveSupport::Notifications.instrument "datadoge", action: :increment, tags: tags, measurement: "sql.#{command}" if command.present?
      end

      ActiveSupport::Notifications.subscribe("datadoge") do |_name, _started, _finished, _unique_id, data|
        send_event_to_statsd(data) if Datadoge.configuration.environments.include?(Rails.env)
      end

      def send_event_to_statsd(data)
        measurement = data.fetch(:measurement)
        key_name = "#{Datadoge.configuration.prefix}.#{measurement}"
        tags = data.fetch(:tags)
        action = data.fetch(:action)

        case action
        when :increment then $statsd.increment key_name, tags: tags
        when :histogram then $statsd.histogram key_name, data.fetch(:value), tags: tags
        else raise "Unknown action: #{action}"
        end
      end
    end
  end
end
