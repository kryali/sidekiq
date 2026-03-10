# frozen_string_literal: true

require_relative "helper"
require "sidekiq/client"
require "sidekiq/middleware/chain"

class BulkMiddlewareTest < Minitest::Test
  def setup
    reset!
  end

  class BulkAwareMiddleware
    class << self
      attr_accessor :calls
    end

    def call_bulk(job_class, payloads, queue, redis_pool)
      self.class.calls += 1
      # Drop one job if it has a specific arg
      payloads = payloads.map do |p|
        if p && p["args"].first == "drop_me"
          nil
        else
          p
        end
      end
      yield payloads
    end
  end

  class LegacyMiddleware
    class << self
      attr_accessor :calls
    end

    def call(job_class, payload, queue, redis_pool)
      self.class.calls += 1
      yield
    end
  end

  def test_bulk_aware_middleware_is_called_once
    BulkAwareMiddleware.calls = 0
    Sidekiq.configure_client do |config|
      config.client_middleware do |chain|
        chain.add BulkAwareMiddleware
      end
    end

    client = Sidekiq::Client.new
    jids = client.push_bulk("class" => "MyJob", "args" => [[1], [2], [3]])
    
    assert_equal 1, BulkAwareMiddleware.calls
    assert_equal 3, jids.compact.size
  end

  def test_bulk_aware_middleware_can_drop_jobs
    BulkAwareMiddleware.calls = 0
    Sidekiq.configure_client do |config|
      config.client_middleware do |chain|
        chain.add BulkAwareMiddleware
      end
    end

    client = Sidekiq::Client.new
    jids = client.push_bulk("class" => "MyJob", "args" => [[1], ["drop_me"], [3]])
    
    assert_equal 1, BulkAwareMiddleware.calls
    assert_equal 3, jids.size
    assert_nil jids[1]
    assert_equal 2, jids.compact.size
  end

  def test_legacy_middleware_is_called_per_job
    LegacyMiddleware.calls = 0
    Sidekiq.configure_client do |config|
      config.client_middleware do |chain|
        chain.add LegacyMiddleware
      end
    end

    client = Sidekiq::Client.new
    jids = client.push_bulk("class" => "MyJob", "args" => [[1], [2], [3]])
    
    assert_equal 3, LegacyMiddleware.calls
    assert_equal 3, jids.size
  end

  def test_mixed_middleware_chain
    BulkAwareMiddleware.calls = 0
    LegacyMiddleware.calls = 0

    Sidekiq.configure_client do |config|
      config.client_middleware do |chain|
        chain.add BulkAwareMiddleware
        chain.add LegacyMiddleware
      end
    end

    client = Sidekiq::Client.new
    jids = client.push_bulk("class" => "MyJob", "args" => [[1], ["drop_me"], [3]])
    
    assert_equal 1, BulkAwareMiddleware.calls
    # legacy should only be called for non-dropped jobs (1 and 3)
    assert_equal 2, LegacyMiddleware.calls
    assert_equal 3, jids.size
    assert_nil jids[1]
  end

  def test_legacy_before_bulk_middleware_chain
    LegacyMiddleware.calls = 0
    BulkAwareMiddleware.calls = 0

    Sidekiq.configure_client do |config|
      config.client_middleware do |chain|
        chain.add LegacyMiddleware
        chain.add BulkAwareMiddleware
      end
    end

    client = Sidekiq::Client.new
    jids = client.push_bulk("class" => "MyJob", "args" => [[1], ["drop_me"], [3]])
    
    assert_equal 3, LegacyMiddleware.calls
    # bulk is called via traverse_bulk inside the legacy fallback map,
    # so it will be called 3 times with arrays of 1 element.
    assert_equal 3, BulkAwareMiddleware.calls
    assert_equal 3, jids.size
    assert_nil jids[1]
  end
end
