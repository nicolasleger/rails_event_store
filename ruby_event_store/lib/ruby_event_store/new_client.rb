module RubyEventStore
  class NewClient

    extend Forwardable

    def_delegators :@old_client, :publish_event, :publish_events

    def initialize(repository:)
      @repository = repository
      @old_client = Client.new(repository: repository)
    end

    def read_stream_events_forward(stream_name)
      read.stream(stream_name).forward.each.to_a
    end

    private

    def read
      Specification.new(@repository)
    end

    class Specification

      def initialize(repository)
        @repository = repository
      end

      def stream(stream_name)
        @stream_name = stream_name
        self
      end

      def forward
        self
      end

      def each
        @repository.read_events_forward(@stream_name, :head, 1)
      end

    end

  end
end

