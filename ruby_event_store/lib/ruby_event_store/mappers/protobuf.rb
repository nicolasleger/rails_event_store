module RubyEventStore
  module Mappers
    class Protobuf
      def initialize(event_id_getter: :event_id, events_class_remapping: {})
        @event_id_getter = event_id_getter
        @events_class_remapping = events_class_remapping
      end

      def event_to_serialized_record(domain_event)
        SerializedRecord.new(
          event_id:   domain_event.public_send(event_id_getter),
          metadata:   "",
          data:       domain_event.class.encode(domain_event),
          event_type: domain_event.class.name
        )
      end

      def serialized_record_to_event(record)
        event_type = events_class_remapping.fetch(record.event_type) { record.event_type }
        Object.const_get(event_type).decode(record.data)
      end

      def add_metadata(event, key, value)
        setter = "#{key}="
        if event.respond_to?(setter)
          event.public_send(setter, value)
        end
      end

      private

      attr_reader :event_id_getter, :events_class_remapping
    end
  end
end