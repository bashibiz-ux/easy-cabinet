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
    rich = CM.news('https://example.com/n.json', feed('items' => [{ 'title' => 'T', 'author' => 'Boris', 'avatar' => 'http://x/a.png', 'html' => '<p>Hi</p>' + ('x' * 30_000) }])).dig('data', 'items', 0)
    assert_equal ['Boris', ''], rich.values_at('author', 'avatar'), 'an avatar must be https'
    assert_equal CM::HTML_LIMIT, rich['html'].length
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

  ATOM = <<~XML
    <?xml version="1.0" encoding="UTF-8"?>
    <feed xmlns="http://www.w3.org/2005/Atom">
      <title>Discussions</title>
      <entry>
        <id>tag:github.com,2008:Discussion/1</id>
        <updated>2026-10-20T10:11:12Z</updated>
        <link rel="alternate" type="text/html" href="https://github.com/me/easy-cabinet/discussions/1"/>
        <title>Sliding doors &amp; tracks</title>
        <author><name>sam</name></author>
        <media:thumbnail height="30" width="30" url="https://avatars.githubusercontent.com/u/1?s=30&amp;v=4"/>
        <content type="html">&lt;p dir=&quot;auto&quot;&gt;Do the doors &amp;amp; tracks fit?&lt;/p&gt;&lt;p&gt;Second line&lt;br&gt;third&lt;/p&gt;</content>
      </entry>
      <entry><title>Hello</title><link rel="alternate" href="https://github.com/me/easy-cabinet/discussions/2"/><updated>2026-10-21T00:00:00Z</updated></entry>
    </feed>
  XML

  def test_the_forum_can_be_the_github_discussions_of_a_repository
    asked = nil
    answer = CM.forum('', ->(url) { asked = url; ATOM }, 'me/easy-cabinet')
    assert answer['ok']
    assert_equal 'https://github.com/me/easy-cabinet/discussions.atom', asked
    assert_equal 'https://github.com/me/easy-cabinet/discussions/new/choose', answer['data']['new_url']
    topics = answer['data']['topics']
    assert_equal ['Sliding doors & tracks', 'sam', '2026-10-20', 'https://github.com/me/easy-cabinet/discussions/1'], topics[0].values_at('title', 'author', 'date', 'url')
    assert_equal 'Hello', topics[1]['title']
    assert_equal "Do the doors & tracks fit?\nSecond line\nthird", topics[0]['body'], 'the post is plain text for the panel'
    assert_equal '', topics[1]['body']
    assert_equal 'https://avatars.githubusercontent.com/u/1?s=80&v=4', topics[0]['avatar'], 'the author picture, larger'
    assert_equal '', topics[1]['avatar']
  end

  def test_a_topic_comes_with_its_replies_oldest_first
    data = { 'topics' => [{ 'title' => 'T', 'author' => 'a', 'replies' => 0, 'comments' => [
      { 'author' => 'Sam', 'avatar' => 'https://avatars.githubusercontent.com/u/2', 'date' => '2026-10-24', 'body' => "Yes\n\nit works" },
      { 'author' => 'Kim', 'avatar' => 'http://bad/x.png', 'body' => 'Thanks' }, { 'author' => 'Empty', 'body' => '  ' }, 'junk'] }] }
    topic = CM.forum('https://example.com/forum.json', feed(data), '').dig('data', 'topics', 0)
    assert_equal 2, topic['comments'].length
    assert_equal 2, topic['replies'], 'the number of replies follows what is shown'
    assert_equal ['Sam', "Yes\n\nit works"], topic['comments'][0].values_at('author', 'body')
    assert_equal '', topic['comments'][1]['avatar'], 'only an https picture'
  end

  def test_the_atom_feed_is_the_way_out_when_the_file_with_the_replies_is_missing
    asked = []
    reader = lambda do |url|
      asked << url
      raise 'The server answered 404.' unless url.end_with?('.atom')

      ATOM
    end
    answer = CM.forum('https://example.com/forum.json', reader, 'me/easy-cabinet')
    assert answer['ok']
    assert_equal ['https://example.com/forum.json', 'https://github.com/me/easy-cabinet/discussions.atom'], asked
    assert_equal 2, answer['data']['topics'].length
    refute CM.forum('https://example.com/forum.json', reader, '')['ok'], 'with no repository there is no way out'
  end

  def test_a_repository_name_is_checked
    assert_equal 'me/easy-cabinet', CM.repo(' me/easy-cabinet ')
    assert_equal '', CM.repo('me')
    assert_equal '', CM.repo('https://github.com/me/x')
    assert_equal '', CM.repo('')
  end

  def test_the_support_goal_shows_the_target_what_was_raised_and_what_is_left
    answer = CM.support('https://example.com/s.json', feed('objective' => 'Version 2.0', 'target' => 1000, 'raised' => 340.5, 'contributors' => 12, 'text' => 'Thank you'))
    assert answer['ok']
    assert_equal ['Version 2.0', 1000.0, 340.5, 659.5, 34, 12], answer['data'].values_at('objective', 'target', 'raised', 'remaining', 'percent', 'contributors')
    over = CM.support('https://example.com/s.json', feed('target' => 500, 'raised' => 900)).fetch('data')
    assert_equal [0.0, 100], over.values_at('remaining', 'percent'), 'a goal that is passed is full, with nothing left'
    refute CM.support('https://example.com/s.json', feed('target' => 0, 'raised' => 5))['ok'], 'a goal needs a target'
    refute CM.support('')['ok']
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
    assert CM.setting('news_url').empty? || CM.setting('news_url').start_with?('https://'), 'an address of the web, or none yet'
    assert_equal '', CM.setting('missing_key')
  end
end
