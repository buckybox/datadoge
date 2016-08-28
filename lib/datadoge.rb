require 'datadoge/version'
require 'gem_config'
require 'statsd'

module Datadoge
  include GemConfig::Base

  with_configuration do
    has :environments, classes: Array, default: ['production']
    has :prefix, classes: [Symbol, String], default: 'rails'
    has :tags, classes: Array, default: ["host:#{ENV['INSTRUMENTATION_HOSTNAME']},role:#{Rails.application.class.parent_name}"]
  end

  class Railtie < Rails::Railtie
    initializer 'datadoge.configure_rails_initialization' do |_app|
      $statsd = Statsd.new

      ActiveSupport::Notifications.subscribe(/process_action.action_controller/) do |*args|
        event = ActiveSupport::Notifications::Event.new(*args)
        controller = "controller:#{event.payload.fetch(:controller)}"
        action = "action:#{event.payload.fetch(:action)}"
        controller_action = "controller_action:#{event.payload.fetch(:controller)}##{event.payload.fetch(:action)}"
        format = "format:#{event.payload.fetch(:format, 'all')}"
        format = 'format:all' if format == 'format:*/*'
        status = event.payload.fetch(:status, 500)
        tags = [controller, action, controller_action, format] + Datadoge.configuration.tags

        ActiveSupport::Notifications.instrument :performance, action: :timing, tags: tags, measurement: 'request.total_duration', value: event.duration
        ActiveSupport::Notifications.instrument :performance, action: :timing, tags: tags,  measurement: 'database.query.time', value: event.payload[:db_runtime]
        ActiveSupport::Notifications.instrument :performance, action: :timing, tags: tags,  measurement: 'web.view.time', value: event.payload[:view_runtime]
        ActiveSupport::Notifications.instrument :performance, action: :increment, tags: tags, measurement: "request.status.#{status}"
      end

      ActiveSupport::Notifications.subscribe(/performance/) do |_name, _start, _finish, _id, payload|
        send_event_to_statsd(payload) if Datadoge.configuration.environments.include?(Rails.env)
      end

      def send_event_to_statsd(payload)
        measurement = payload.fetch(:measurement)
        key_name = "#{Datadoge.configuration.prefix}.#{measurement}"
        tags = payload.fetch(:tags)
        action = payload.fetch(:action)

        if action == :increment
          $statsd.increment key_name, tags: tags
        else
          value = payload.fetch(:value)
          $statsd.histogram key_name, value, tags: tags
        end
      end
    end
  end
end
