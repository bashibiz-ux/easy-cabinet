# frozen_string_literal: true

# The monthly support goal: when the extension is stopped, what it says, and that the author is never held to it. Run:  ruby test/support_status_test.rb

require 'json'
require 'minitest/autorun'
require 'tmpdir'
require 'digest'

module Sketchup
  @store = {}
  class << self
    def read_default(section, key, default = nil) = (@store ||= {}).fetch([section, key], default)
    def write_default(section, key, value) = ((@store ||= {})[[section, key]] = value)
  end
end
module EasyCabinet
  module CatalogManager
    class << self
      attr_accessor :folder

      def user_root = folder
      private :user_root
    end
  end
end
require File.join(File.expand_path('../easy_cabinet', __dir__), 'support_status')

class SupportStatusTest < Minitest::Test
  include EasyCabinet

  SET = { 'status_url' => 'https://example.org/status.json', 'monthly_target' => 1000.0, 'currency' => 'USD', 'grace_days' => 10, 'developer_hash' => '', 'donation_url' => 'https://example.org/donate' }.freeze

  def cache(raised, month: '2026-11', target: nil, at: Time.utc(2026, 11, 3))
    status = { 'month' => month, 'raised' => raised }
    status['target'] = target if target
    { 'status' => status, 'fetched_at' => at.to_f }
  end

  def run_at(day, raised, settings: SET, developer: false, **cache_options)
    now = Time.utc(2026, 11, day, 12)
    SupportStatus.evaluate(settings, cache(raised, at: now - 3600, **cache_options), now, developer)
  end

  def test_nothing_is_stopped_until_a_status_address_is_set_up
    state = SupportStatus.evaluate(SET.merge('status_url' => ''), nil, Time.utc(2026, 11, 20), false)
    assert_equal 'off', state['mode']
    refute state['locked']
  end

  def test_the_extension_is_never_stopped_for_the_author
    state = run_at(25, 0.0, settings: SET.merge('developer_hash' => 'x'), developer: true)
    assert_equal 'developer', state['mode']
    refute state['locked']
  end

  def test_it_goes_on_working_when_no_status_could_be_read_or_it_is_old_or_of_another_month
    now = Time.utc(2026, 11, 25)
    refute SupportStatus.evaluate(SET, nil, now, false)['locked'], 'no status yet'
    old = cache(0.0, at: now - (20 * 86_400))
    refute SupportStatus.evaluate(SET, old, now, false)['locked'], 'a status that could not be refreshed for 20 days'
    other = cache(0.0, month: '2026-10', at: now - 3600)
    state = SupportStatus.evaluate(SET, other, now, false)
    assert_equal 'unknown', state['mode']
    refute state['locked'], "last month's figure says nothing about this month"
  end

  def test_in_the_first_days_it_works_and_asks
    state = run_at(10, 120.0)
    assert_equal 'grace', state['mode']
    refute state['locked']
    assert_equal 12, state['percent']
    assert_includes state['message'], 'USD 1000'
    assert_includes state['message'], 'USD 120'
    assert_includes state['message'], 'donate'
  end

  def test_after_the_grace_days_it_stops_until_the_target_is_reached
    state = run_at(11, 999.99)
    assert_equal 'locked', state['mode']
    assert state['locked']
    assert_equal 99, state['percent']
    assert_includes state['message'], 'monthly target is USD 1000 and we have reached USD 999.99'
    assert_includes state['message'], 'Please donate to keep Easy Cabinet alive'
    assert_equal 'https://example.org/donate', state['donate_url']
  end

  def test_when_the_target_is_reached_it_works_all_month
    [1, 11, 28].each do |day|
      state = run_at(day, 1000.0)
      assert_equal 'funded', state['mode'], "day #{day}"
      refute state['locked']
      assert_equal 100, state['percent']
    end
    assert_equal 100, run_at(15, 2500.0)['percent'], 'never more than 100 %'
  end

  def test_a_target_in_the_status_file_wins_over_the_one_in_the_settings
    state = run_at(15, 600.0, target: 500)
    assert_equal 'funded', state['mode']
    assert_equal 500.0, state['target']
  end

  def test_the_settings_are_checked
    Dir.mktmpdir do |dir|
      path = File.join(dir, 'config.json')
      File.write(path, JSON.generate('status_url' => ' https://a.b/c.json ', 'monthly_target' => -5, 'grace_days' => 99, 'currency' => '', 'developer_hash' => 'ABC'))
      conf = SupportStatus.settings(path)
      assert_equal 'https://a.b/c.json', conf['status_url']
      assert_equal 1000.0, conf['monthly_target']
      assert_equal 10, conf['grace_days']
      assert_equal 'USD', conf['currency']
      assert_equal 'abc', conf['developer_hash']
      assert_equal SupportStatus::DEFAULTS['monthly_target'], SupportStatus.settings(File.join(dir, 'none.json'))['monthly_target']
    end
  end

  def test_the_status_file_is_read_with_care
    ok = SupportStatus.parse('{"month":"2026-11","target":1000,"raised":372.5,"currency":"USD"}')
    assert_equal({ 'month' => '2026-11', 'raised' => 372.5, 'target' => 1000.0, 'currency' => 'USD' }, ok)
    assert_nil SupportStatus.parse('not json')
    assert_nil SupportStatus.parse('{"month":"November","raised":5}')
    assert_nil SupportStatus.parse('{"month":"2026-11","raised":"lots"}')
    assert_nil SupportStatus.parse('{"month":"2026-11","raised":-1}')
    assert_equal({ 'month' => '2026-11', 'raised' => 0.0 }, SupportStatus.parse('{"month":"2026-11","raised":0,"target":-4}'))
  end

  def test_the_author_is_the_one_who_has_the_key_file
    Dir.mktmpdir do |dir|
      CatalogManager.folder = dir
      conf = SET.merge('developer_hash' => Digest::SHA256.hexdigest('secret-key'))
      refute SupportStatus.developer?(conf), 'no key file'
      File.write(File.join(dir, 'developer.key'), "wrong\n")
      refute SupportStatus.developer?(conf), 'a wrong key'
      File.write(File.join(dir, 'developer.key'), "secret-key\n")
      assert SupportStatus.developer?(conf), 'the key'
      refute SupportStatus.developer?(SET), 'no hash in the settings: nobody is the author'
    end
  ensure
    CatalogManager.folder = nil
  end

  def test_a_status_that_was_read_is_kept_for_the_next_start
    assert_nil SupportStatus.send(:read_cache)
    SupportStatus.send(:write_cache, 'status' => { 'month' => '2026-11', 'raised' => 5.0 }, 'fetched_at' => 1.0)
    assert_equal 5.0, SupportStatus.send(:read_cache)['status']['raised']
    refute_includes Sketchup.read_default('EasyCabinet', SupportStatus::CACHE_KEY), '"', 'kept as base64 (SketchUp cannot read back quotes)'
  end
end
