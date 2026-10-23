# frozen_string_literal: true

require 'json'
require 'net/http'
require 'uri'

module EasyCabinet
  # The News and Forum windows of the More menu. Both show a list that is read from a small JSON file on the web, only when the user opens the window
  # (nothing is sent: the file is just read). The addresses are in easy_cabinet/config.json:
  #   news_url       the news file:   { "items":  [{ "title", "date", "text", "url" }] }
  #   forum_url      the forum file:  { "topics": [{ "title", "author", "date", "replies", "tags": [], "url" }], "new_url": "https://..." }
  #   forum_new_url  where "Start a conversation" leads (when the forum file does not say)
  # A topic, an article or a new conversation is opened in the browser, on the site that hosts it.
  module CommunityManager
    MAX_BYTES = 512 * 1024
    MAX_ITEMS = 40
    TIMEOUT = 8 # seconds

    # The setting of config.json called `key`, '' when there is none.
    def self.setting(key, path = FeedbackManager::CONFIG_PATH)
      stored = begin
        JSON.parse(File.read(path, encoding: 'UTF-8'))
      rescue StandardError
        {}
      end
      stored.is_a?(Hash) ? stored[key].to_s.strip : ''
    end

    # The text of a web address (https only) => the body, or raises with the reason.
    def self.fetch(url, redirects = 3)
      uri = URI.parse(url)
      raise 'The address must start with https://.' unless uri.is_a?(URI::HTTPS)

      Net::HTTP.start(uri.host, uri.port, use_ssl: true, open_timeout: TIMEOUT, read_timeout: TIMEOUT) do |http|
        response = http.request(Net::HTTP::Get.new(uri))
        if response.is_a?(Net::HTTPRedirection) && redirects.positive?
          return fetch(URI.join(url, response['location']).to_s, redirects - 1)
        end
        raise "The server answered #{response.code}." unless response.is_a?(Net::HTTPSuccess)
        raise 'The list is too big.' if response.body.to_s.bytesize > MAX_BYTES

        response.body.to_s.dup.force_encoding('UTF-8')
      end
    end

    def self.text(value, limit)
      value.to_s.gsub(/[[:cntrl:]]/, ' ').strip[0, limit]
    end

    # A link that may be opened: https, or ''.
    def self.link(value)
      url = value.to_s.strip
      url.start_with?('https://') && !url.match?(/\s/) ? url : ''
    end

    def self.news_items(data)
      list = data.is_a?(Hash) ? data['items'] : nil
      Array(list).first(MAX_ITEMS).filter_map do |item|
        next unless item.is_a?(Hash) && !text(item['title'], 160).empty?

        { 'title' => text(item['title'], 160), 'date' => text(item['date'], 30), 'text' => text(item['text'], 600), 'url' => link(item['url']) }
      end
    end

    def self.forum_topics(data)
      list = data.is_a?(Hash) ? data['topics'] : nil
      Array(list).first(MAX_ITEMS).filter_map do |topic|
        next unless topic.is_a?(Hash) && !text(topic['title'], 160).empty?

        { 'title' => text(topic['title'], 160), 'author' => text(topic['author'], 60), 'date' => text(topic['date'], 30), 'replies' => topic['replies'].to_i.clamp(0, 99_999),
          'tags' => Array(topic['tags']).first(5).map { |tag| text(tag, 24) }.reject(&:empty?), 'url' => link(topic['url']) }
      end
    end

    # The News window: => Response with { 'items' => [...] }.
    def self.news(url = setting('news_url'), reader = method(:fetch))
      return Response.fail('The news are not set up yet.') if url.to_s.empty?

      Response.ok('', { 'items' => news_items(JSON.parse(reader.call(url))) })
    rescue StandardError => e
      Response.fail("Unable to load the news list. #{e.message}")
    end

    # The Forum window: => Response with { 'topics' => [...], 'new_url' => '...' }.
    def self.forum(url = setting('forum_url'), reader = method(:fetch))
      new_url = link(setting('forum_new_url'))
      return Response.fail('The forum is not set up yet.') if url.to_s.empty? && new_url.empty?
      return Response.ok('', { 'topics' => [], 'new_url' => new_url }) if url.to_s.empty?

      data = JSON.parse(reader.call(url))
      Response.ok('', { 'topics' => forum_topics(data), 'new_url' => new_url.empty? ? link(data['new_url']) : new_url })
    rescue StandardError => e
      Response.fail("Unable to load the topic list. #{e.message}")
    end

    # A link of the lists (an article, a topic, a new conversation) opens in the browser.
    def self.open_link(raw)
      url = link(raw['url'])
      return Response.fail('That link cannot be opened.') if url.empty?

      UI.openURL(url)
      Response.ok('Opened in your browser.')
    end
  end
end
