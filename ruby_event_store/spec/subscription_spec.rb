require 'spec_helper'

class CustomDispatcher
  attr_reader :dispatched_events

  def initialize
    @dispatched_events = []
  end

  def call(subscriber, event)
    subscriber = subscriber.new if Class === subscriber
    @dispatched_events << {to: subscriber.class, event: event}
  end

  def verify(subscriber)
    subscriber = subscriber.new if Class === subscriber
    subscriber.respond_to?(:call) or raise InvalidHandler.new(subscriber)
  rescue ArgumentError
    raise InvalidHandler.new(subscriber)
  end
end

module RubyEventStore
  RSpec.describe Client do

    def silence_stderr
      $stderr = StringIO.new
      yield
    ensure
      $stderr = STDERR
    end

    around(:each) do |example|
      silence_stderr { example.run }
    end

    let(:repository) { InMemoryRepository.new }
    let(:client)     { RubyEventStore::Client.new(repository: repository) }

    specify 'throws exception if subscriber is not defined' do
      expect { client.subscribe(nil, [])}.to raise_error(SubscriberNotExist)
      expect { client.subscribe_to_all_events(nil)}.to raise_error(SubscriberNotExist)
    end

    specify 'throws exception if subscriber has not call method - handling subscribed events' do
      subscriber = Subscribers::InvalidHandler.new
      expect { client.subscribe(subscriber, to: [OrderCreated]) }.to raise_error(InvalidHandler)
    end

    specify 'throws exception if subscriber has not call method - handling all events' do
      subscriber = Subscribers::InvalidHandler.new
      expect { client.subscribe_to_all_events(subscriber) }.to raise_error(InvalidHandler)
    end

    specify 'notifies subscribers listening on all events' do
      subscriber = Subscribers::ValidHandler.new
      client.subscribe_to_all_events(subscriber)
      event = OrderCreated.new
      client.publish_event(event)
      expect(subscriber.handled_events).to eq [event]
    end

    specify 'notifies subscribers listening on list of events (deprecated)' do
      subscriber = Subscribers::ValidHandler.new
      expect do
        client.subscribe(subscriber, [OrderCreated, ProductAdded])
      end.to output("#{Client::DEPRECATED_TO}\n").to_stderr
      event_1 = OrderCreated.new
      event_2 = ProductAdded.new
      client.publish_event(event_1)
      client.publish_event(event_2)
      expect(subscriber.handled_events).to eq [event_1, event_2]
    end

    specify 'notifies subscribers listening on list of events' do
      subscriber = Subscribers::ValidHandler.new
      client.subscribe(subscriber, to: [OrderCreated, ProductAdded])
      event_1 = OrderCreated.new
      event_2 = ProductAdded.new
      client.publish_event(event_1)
      client.publish_event(event_2)
      expect(subscriber.handled_events).to eq [event_1, event_2]
    end

    specify 'notifies subscribers listening on all events - with lambda' do
      handled_events = []
      subscriber = ->(event) {
        handled_events << event
      }
      client.subscribe_to_all_events(subscriber)
      event = OrderCreated.new
      client.publish_event(event)
      expect(handled_events).to eq [event]
    end

    specify 'notifies subscribers listening on all events - with proc (v2 API)' do
      event_1 = OrderCreated.new
      event_2 = ProductAdded.new
      subscriber = Subscribers::ValidHandler.new
      unsub = client.subscribe_to_all_events do |ev|
        subscriber.call(ev)
      end
      client.publish_event(event_1)
      unsub.()
      client.publish_event(event_2)
      expect(subscriber.handled_events).to eq [event_1]
      expect(client.read_all_streams_forward).to eq([event_1, event_2])
    end

    specify 'notifies subscribers listening on list of events - with lambda' do
      handled_events = []
      subscriber = ->(event) {
        handled_events << event
      }
      client.subscribe(subscriber, to: [OrderCreated, ProductAdded])
      event_1 = OrderCreated.new
      event_2 = ProductAdded.new
      client.publish_event(event_1)
      client.publish_event(event_2)
      expect(handled_events).to eq [event_1, event_2]
    end

    specify 'notifies subscribers listening on list of events - with proc (v2)' do
      handled_events = []
      client.subscribe(to: [OrderCreated, ProductAdded]) do |event|
        handled_events << event
      end
      event_1 = OrderCreated.new
      event_2 = ProductAdded.new
      client.publish_event(event_1)
      client.publish_event(event_2)
      expect(handled_events).to eq [event_1, event_2]
    end

    specify 'allows to provide a custom dispatcher' do
      dispatcher = CustomDispatcher.new
      broker = PubSub::Broker.new(dispatcher: dispatcher)
      client = RubyEventStore::Client.new(repository: repository, event_broker: broker)
      subscriber = Subscribers::ValidHandler.new
      client.subscribe(subscriber, to: [OrderCreated])
      event = OrderCreated.new
      client.publish_event(event)
      expect(dispatcher.dispatched_events).to eq [{to: Subscribers::ValidHandler, event: event}]
    end

    specify 'lambda is an output of subscribe methods' do
      subscriber = Subscribers::ValidHandler.new
      result = client.subscribe(subscriber, [OrderCreated,ProductAdded])
      expect(result).to respond_to(:call)
    end

    specify 'dynamic global subscription (deprecated)' do
      event_1 = OrderCreated.new
      event_2 = ProductAdded.new
      subscriber = Subscribers::ValidHandler.new
      result = nil
      expect do
        result = client.subscribe_to_all_events(subscriber) do
          client.publish_event(event_1)
        end
      end.to output("#{Client::DEPRECATED_ALL_WITHIN}\n").to_stderr
      client.publish_event(event_2)
      expect(subscriber.handled_events).to eq [event_1]
      expect(client.read_all_streams_forward).to eq([event_1, event_2])
      result.call()
    end

    specify 'dynamic subscription (deprecated)' do
      event_1 = OrderCreated.new
      event_2 = ProductAdded.new
      subscriber = Subscribers::ValidHandler.new
      result = nil
      expect do
        result = client.subscribe(subscriber, [OrderCreated, ProductAdded]) do
          client.publish_event(event_1)
        end
      end.to output("#{Client::DEPRECATED_WITHIN}\n").to_stderr
      client.publish_event(event_2)
      expect(subscriber.handled_events).to eq [event_1]
      expect(client.read_all_streams_forward).to eq([event_1, event_2])
      result.()
    end

    specify 'dynamic subscription' do
      event_1 = OrderCreated.new
      event_2 = ProductAdded.new
      subscriber = Subscribers::ValidHandler.new
      client.within do
        client.publish_event(event_1)
      end.subscribe(subscriber, to: [OrderCreated, ProductAdded]).call
      client.publish_event(event_2)
      expect(subscriber.handled_events).to eq [event_1]
      expect(client.read_all_streams_forward).to eq([event_1, event_2])
    end

    specify 'subscribers receive event with enriched metadata' do
      client = RubyEventStore::Client.new(repository: repository, clock: ->{ Time.at(0) })
      received_event = nil
      client.subscribe(to: [OrderCreated]) do |event|
        received_event = event
      end
      client.publish_event(OrderCreated.new)

      expect(received_event).to_not be_nil
      expect(received_event.metadata[:timestamp]).to eq(Time.at(0))
    end

    specify 'throws exception if subscriber klass does not have call method - handling subscribed events' do
      expect do
        client.subscribe(Subscribers::InvalidHandler, to: [OrderCreated])
      end.to raise_error(InvalidHandler)
    end

    specify 'throws exception if subscriber klass have not call method - handling all events' do
      expect do
        client.subscribe_to_all_events(Subscribers::InvalidHandler)
      end.to raise_error(InvalidHandler)
    end

    specify 'dispatch events to subscribers via proxy' do
      dispatcher = CustomDispatcher.new
      broker = PubSub::Broker.new(dispatcher: dispatcher)
      client = RubyEventStore::Client.new(repository: repository, event_broker: broker)
      client.subscribe(Subscribers::ValidHandler, to: [OrderCreated])
      event = OrderCreated.new
      client.publish_event(event)
      expect(dispatcher.dispatched_events).to eq [{to: Subscribers::ValidHandler, event: event}]
    end

    specify 'dispatch all events to subscribers via proxy' do
      dispatcher = CustomDispatcher.new
      broker = PubSub::Broker.new(dispatcher: dispatcher)
      client = RubyEventStore::Client.new(repository: repository, event_broker: broker)
      client.subscribe_to_all_events(Subscribers::ValidHandler)
      event = OrderCreated.new
      client.publish_event(event)
      expect(dispatcher.dispatched_events).to eq [{to: Subscribers::ValidHandler, event: event}]
    end

    specify 'lambda is an output of global subscribe via proxy' do
      dispatcher = CustomDispatcher.new
      broker = PubSub::Broker.new(dispatcher: dispatcher)
      client = RubyEventStore::Client.new(repository: repository, event_broker: broker)
      result = client.subscribe_to_all_events(Subscribers::ValidHandler)
      expect(result).to respond_to(:call)
    end

    specify 'lambda is an output of subscribe via proxy' do
      dispatcher = CustomDispatcher.new
      broker = PubSub::Broker.new(dispatcher: dispatcher)
      client = RubyEventStore::Client.new(repository: repository, event_broker: broker)
      result = client.subscribe(Subscribers::ValidHandler, to: [OrderCreated])
      expect(result).to respond_to(:call)
    end

    specify 'dynamic global subscription via proxy' do
      event_1 = OrderCreated.new
      event_2 = ProductAdded.new
      dispatcher = CustomDispatcher.new
      broker = PubSub::Broker.new(dispatcher: dispatcher)
      client = RubyEventStore::Client.new(repository: repository, event_broker: broker)
      result = client.within do
        client.publish_event(event_1)
        :elo
      end.subscribe_to_all_events(Subscribers::ValidHandler).call
      client.publish_event(event_2)
      expect(dispatcher.dispatched_events).to eq [{to: Subscribers::ValidHandler, event: event_1}]
      expect(result).to eq(:elo)
      expect(client.read_all_streams_forward).to eq([event_1, event_2])
    end

    specify 'dynamic subscription (deprecated)' do
      event_1 = OrderCreated.new
      event_2 = ProductAdded.new
      event_3 = ProductAdded.new
      types = [OrderCreated, ProductAdded]
      result = h = nil
      expect do
        result = client.subscribe(h = Subscribers::ValidHandler.new, types) do
          client.publish_event(event_1)
          client.publish_event(event_2)
        end
      end.to output("#{Client::DEPRECATED_WITHIN}\n").to_stderr
      client.publish_event(event_3)
      expect(h.handled_events).to eq([event_1, event_2])
      expect(result).to respond_to(:call)
      expect(client.read_all_streams_forward).to eq([event_1, event_2, event_3])
    end

    specify 'dynamic subscription with exception (deprecated)' do
      event_1 = OrderCreated.new
      event_2 = OrderCreated.new
      exception = Class.new(StandardError)
      h = nil
      expect do
        begin
          client.subscribe(h = Subscribers::ValidHandler.new, [OrderCreated]) do
            client.publish_event(event_1)
            raise exception
          end
        rescue exception
        end
      end.to output("#{Client::DEPRECATED_WITHIN}\n").to_stderr
      client.publish_event(event_2)
      expect(h.handled_events).to eq([event_1])
      expect(client.read_all_streams_forward).to eq([event_1, event_2])
    end

    specify 'notifies subscriber in the order events were published' do
      handled_events = []
      subscriber = ->(event) {
        handled_events << event
      }
      client.subscribe(subscriber, to: [ProductAdded, OrderCreated])
      event_1 = OrderCreated.new
      event_2 = ProductAdded.new
      client.publish_events([event_1, event_2])
      expect(handled_events).to eq [event_1, event_2]
    end

    specify 'with many subscribers they are called in the order events were published' do
      handled_events = []
      subscriber1 = ->(event) {
        handled_events << event
        handled_events << :subscriber1
      }
      client.subscribe(subscriber1, to: [ProductAdded, OrderCreated])
      subscriber2 = ->(event) {
        handled_events << event
        handled_events << :subscriber2
      }
      client.subscribe(subscriber2, to: [ProductAdded, OrderCreated])
      event_1 = OrderCreated.new
      event_2 = ProductAdded.new
      client.publish_events([event_1, event_2])
      expect(handled_events).to eq [
        event_1, :subscriber1, event_1, :subscriber2,
        event_2, :subscriber1, event_2, :subscriber2,
      ]
    end

    specify "subscribe unallowed calls" do
      expect do
        client.subscribe(subscriber = ->(){}, to: [], ){}
      end.to raise_error(ArgumentError, "subscriber must be first argument or block, cannot be both")

      expect do
        client.subscribe(to: [])
      end.to raise_error(RubyEventStore::SubscriberNotExist, "subscriber must be first argument or block")

      expect do
        client.subscribe(-> (){}, [], to: [])
      end.to raise_error(ArgumentError, "list of event types must be second argument or named argument to: , it cannot be both")
    end

    context "dynamic subscribe v2" do
      specify 'dynamic global subscription via proxy' do
        event_1 = OrderCreated.new
        event_2 = ProductAdded.new
        dispatcher = CustomDispatcher.new
        broker = PubSub::Broker.new(dispatcher: dispatcher)
        client = RubyEventStore::Client.new(repository: repository, event_broker: broker)

        result = client.within do
          client.publish_event(event_1)
          :yo
        end.subscribe_to_all_events(Subscribers::ValidHandler).call

        client.publish_event(event_2)

        expect(dispatcher.dispatched_events).to eq [{to: Subscribers::ValidHandler, event: event_1}]
        expect(client.read_all_streams_forward).to eq([event_1, event_2])
        expect(result).to eq(:yo)
      end

      specify 'dynamic subscription' do
        event_1 = OrderCreated.new
        event_2 = ProductAdded.new
        event_3 = ProductAdded.new
        types = [OrderCreated, ProductAdded]
        result = client.within do
          client.publish_event(event_1)
          client.publish_event(event_2)
          :result
        end.subscribe(h = Subscribers::ValidHandler.new, to: types).call

        client.publish_event(event_3)
        expect(h.handled_events).to eq([event_1, event_2])
        expect(result).to eq(:result)
        expect(client.read_all_streams_forward).to eq([event_1, event_2, event_3])
      end

      specify 'nested dynamic subscription' do
        e1 = e2 = e3 = e4 = e5 = e6 = e7 = e8 = nil
        h1 = h2 = nil
        result = client.within do
          client.publish_event(e1 = ProductAdded.new)
          client.publish_event(e2 = OrderCreated.new)
          client.within do
            client.publish_event(e3 = ProductAdded.new)
            client.publish_event(e4 = OrderCreated.new)
            :result1
          end.subscribe(h2 = Subscribers::ValidHandler.new, to: [OrderCreated]).call
          client.publish_event(e5 = ProductAdded.new)
          client.publish_event(e6 = OrderCreated.new)
          :result2
        end.subscribe(h1 = Subscribers::ValidHandler.new, to: [ProductAdded]).call
        client.publish_event(e7 = ProductAdded.new)
        client.publish_event(e8 = OrderCreated.new)

        expect(h1.handled_events).to eq([e1,e3,e5])
        expect(h2.handled_events).to eq([e4])
        expect(result).to eq(:result2)
        expect(client.read_all_streams_forward).to eq([e1,e2,e3,e4,e5,e6,e7,e8])
      end

      specify 'dynamic subscription with exception' do
        event_1 = OrderCreated.new
        event_2 = OrderCreated.new
        exception = Class.new(StandardError)
        begin
          client.within do
            client.publish_event(event_1)
            raise exception
          end.subscribe(h = Subscribers::ValidHandler.new, to: OrderCreated).call
        rescue exception
        end
        client.publish_event(event_2)
        expect(h.handled_events).to eq([event_1])
        expect(client.read_all_streams_forward).to eq([event_1, event_2])
      end

      specify 'chained subscriptions' do
        event_1 = OrderCreated.new
        event_2 = ProductAdded.new
        event_3 = ProductAdded.new
        h1,h2,h3,h4 = 4.times.map{Subscribers::ValidHandler.new}
        result = client.within do
          client.publish_event(event_1)
          client.publish_event(event_2)
          :result
        end.
        subscribe(h1, to: OrderCreated).
        subscribe_to_all_events(h2).
        subscribe(to: [ProductAdded]) do |ev|
          h3.call(ev)
        end.
        subscribe_to_all_events do |ev|
          h4.call(ev)
        end.
        call

        client.publish_event(event_3)
        expect(h1.handled_events).to eq([event_1])
        expect(h3.handled_events).to eq([event_2])
        expect(h2.handled_events).to eq([event_1, event_2])
        expect(h4.handled_events).to eq([event_1, event_2])
        expect(result).to eq(:result)
        expect(client.read_all_streams_forward).to eq([event_1, event_2, event_3])
      end

      specify "temporary subscriptions don't affect other threads" do
        h1,h2,h3,h4 = 4.times.map{Subscribers::ValidHandler.new}
        big_number = 2_000
        thread = Thread.new do
          client.within do
            big_number.times{ client.publish_event(ProductAdded.new) }
          end.subscribe_to_all_events(h3).subscribe(h4, to: ProductAdded).call
        end
        client.within do
          big_number.times{ client.publish_event(OrderCreated.new) }
        end.subscribe_to_all_events(h1).subscribe(h2, to: OrderCreated).call
        thread.join

        expect(h1.handled_events.count).to eq(big_number)
        expect(h1.handled_events.map(&:class).uniq).to eq([OrderCreated])

        expect(h2.handled_events.count).to eq(big_number)
        expect(h2.handled_events.map(&:class).uniq).to eq([OrderCreated])

        expect(h3.handled_events.count).to eq(big_number)
        expect(h3.handled_events.map(&:class).uniq).to eq([ProductAdded])

        expect(h4.handled_events.count).to eq(big_number)
        expect(h4.handled_events.map(&:class).uniq).to eq([ProductAdded])
      end unless ENV['MUTATING'] == 'true'

    end
  end
end
