# frozen_string_literal: true

# Saved panel settings. Run:  ruby test/preset_test.rb

require 'minitest/autorun'
require 'json'

module Sketchup
  @store = {}
  class << self
    attr_reader :store

    def read_default(section, key, default = nil) = @store.fetch([section, key], default)
    def write_default(section, key, value) = @store[[section, key]] = value
  end
end
module EasyCabinet
  DATA_DIR = 'unused'
end
plugin = File.expand_path('../easy_cabinet', __dir__)
%w[response preset_manager].each { |f| require File.join(plugin, f) }

class PresetTest < Minitest::Test
  include EasyCabinet

  def setup = Sketchup.store.clear

  def test_what_is_saved_comes_back
    PresetManager.perform('save_presets', 'values' => { 'doorGap' => 2.0, 'topPanel' => 'full', 'toeCover' => true })
    answer = PresetManager.perform('load_presets', {})
    assert_equal({ 'doorGap' => 2.0, 'topPanel' => 'full', 'toeCover' => true }, answer['data']['values'])
  end

  def test_nothing_saved_gives_an_empty_answer
    assert_equal({}, PresetManager.perform('load_presets', {})['data']['values'])
  end

  def test_odd_names_and_values_are_left_out
    clean = PresetManager.clean('ok' => 1, 'bad name' => 2, 'nested' => { 'a' => 1 }, 'list' => [1], 'long' => 'x' * 300)
    assert_equal({ 'ok' => 1 }, clean)
  end

  def test_reset_clears_everything
    PresetManager.perform('save_presets', 'values' => { 'a' => 1 })
    PresetManager.perform('reset_presets', {})
    assert_equal({}, PresetManager.perform('load_presets', {})['data']['values'])
  end

  def test_the_saved_text_has_no_quotes_so_sketchup_can_read_it_back
    PresetManager.perform('save_presets', 'values' => { 'doorGap' => 2.0, 'name' => 'a "quoted" word' })
    refute_includes Sketchup.read_default('EasyCabinet', PresetManager::KEY), '"'
  end

  def test_the_old_json_text_is_never_read
    Sketchup.write_default('EasyCabinet', 'panel_presets', '{"doorGap":2.0}')
    reads = []
    Sketchup.define_singleton_method(:read_default) { |section, key, default = nil| reads << key; @store.fetch([section, key], default) }
    assert_equal({}, PresetManager.perform('load_presets', {})['data']['values'])
    assert_equal [PresetManager::KEY], reads.uniq, 'only the new key is read: SketchUp reports an error when it cannot read the old text'
    refute_equal 'panel_presets', PresetManager::KEY
  ensure
    Sketchup.singleton_class.send(:remove_method, :read_default)
    Sketchup.define_singleton_method(:read_default) { |section, key, default = nil| @store.fetch([section, key], default) }
  end

  def test_a_text_sketchup_cannot_read_back_does_not_break_the_panel
    Sketchup.define_singleton_method(:read_default) { |*_| raise SyntaxError, '(eval):1: syntax error' }
    assert_equal({}, PresetManager.perform('load_presets', {})['data']['values'])
  ensure
    Sketchup.singleton_class.send(:remove_method, :read_default)
    Sketchup.define_singleton_method(:read_default) { |section, key, default = nil| @store.fetch([section, key], default) }
  end

  def test_damaged_saved_text_does_not_break_the_panel
    Sketchup.write_default('EasyCabinet', PresetManager::KEY, '{not json')
    assert_equal({}, PresetManager.perform('load_presets', {})['data']['values'])
  end
end