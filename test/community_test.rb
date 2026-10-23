# frozen_string_literal: true

# The News and Forum lists of the More menu. Run:  ruby test/community_test.rb

require 'json'
require 'minitest/autorun'

module UI
  def self.openURL(url) = (@opened = url)

  def self.opened = @opened
end
plugin = File.expand_path('../easy_cabinet', __dir__)
module EasyCabinet; end
%w[response feedback_manager community_manager].each { |f| require File.join(plugin, f) }

class CommunityTest < Minitest::Test
  CM = EasyCabinet::CommunityManager

  def feed(hash) = ->(_url) { JSON.generate(hash) }

  def test_news_are_not_loaded_without_an_address
    refute CM.news('')['ok']
    assert_equal 'The news are not set up yet.', CM.news('')['message']
  end

  def test_the_news_list_is_read_and_cleaned
    data = { 'items' => [{ 'title' => "  Hello\nworld ", 'date' => '2026-10-23', 'text' => 'x' * 900, 'url' => 'https://example.com/a' },
                         { 'title' => 'No link', 'url' => 'javascript:alert(1)' }, { 'title' => '' }, 'junk'] }
    answer = CM.news('https://example.com/news.json', feed(data))
    assert answer['ok']
    items = answer['data']['items']
    assert_equal 2, items.length
    assert_equal 'Hello world', items[0]['title']
    assert_equal 600, items[0]['text'].length
    assert_equal 'https://example.com/a', items[0]['url']
    assert_equal '', items[1]['url'], 'only https links are kept'
  end

  def test_a_list_that_cannot_be_read_gives_a_message
    answer = CM.news('https://example.com/news.json', ->(_url) { raise 'The server answered 404.' })
    refute answer['ok']
    assert_includes answer['message'], 'The server answered 404.'
    refute CM.forum('https://example.com/f.json', ->(_url) { 'not json' })['ok']
  end

  def test_the_forum_topics_and_the_new_conversation_link
    data = { 'new_url' => 'https://forum.example.com/new', 'topics' => [{ 'title' => 'Sliding doors', 'author' => 'Sam', 'replies' => '3', 'tags' => %w[wardrobe a b c d e f], 'url' => 'https://forum.example.com/t/1' }] }
    answer = CM.forum('https://example.com/forum.json', feed(data))
    assert answer['ok']
    topic = answer['data']['topics'].first
    assert_equal [3, 5], [topic['replies'], topic['tags'].length]
  end

  def test_only_an_https_link_is_opened
    assert CM.open_link({ 'url' => 'https://example.com/x' })['ok']
    assert_equal 'https://example.com/x', UI.opened
    refute CM.open_link({ 'url' => 'file:///C:/secret' })['ok']
    refute CM.open_link({ 'url' => 'http://example.com' })['ok']
  end

  def test_the_address_of_a_list_must_be_https
    assert_raises(RuntimeError) { CM.fetch('http://example.com/news.json') }
  end

  def test_the_settings_are_read_from_config_json
    assert_equal '', CM.setting('news_url')
    assert_equal '', CM.setting('missing_key')
  end
end
