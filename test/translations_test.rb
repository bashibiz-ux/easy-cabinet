# frozen_string_literal: true

# The languages of the panel: every language file has the words of keys.txt, every word is one the panel really shows, and the list in
# i18n.js, the files and the script tags of index.html agree.
# Run:  ruby test/translations_test.rb

require 'minitest/autorun'
require 'json'

class TranslationsTest < Minitest::Test
  ROOT = File.expand_path('..', __dir__)
  HTML_DIR = File.join(ROOT, 'easy_cabinet', 'html')
  KEYS = File.read(File.join(ROOT, 'translations', 'keys.txt'), encoding: 'UTF-8').lines.map(&:chomp).reject(&:empty?)
  INDEX = File.read(File.join(HTML_DIR, 'index.html'), encoding: 'UTF-8')
  FILES = Dir[File.join(HTML_DIR, 'lang', '*.js')].sort

  def table(path)
    JSON.parse(File.read(path, encoding: 'UTF-8')[/= (\{.*\});/m, 1])
  end

  def test_there_are_sixteen_languages_besides_english
    assert_equal %w[ar cs de es fr he hu it nl pl pt ru sr uk vi zh], FILES.map { |f| File.basename(f, '.js') }
  end

  def test_every_language_has_every_word
    FILES.each do |path|
      words = table(path)
      assert_equal KEYS.sort, words.keys.sort, "#{File.basename(path)} lacks or adds words"
      assert(words.values.none? { |text| text.strip.empty? })
    end
  end

  def test_every_word_is_one_the_panel_shows
    shown = INDEX.scan(/>([^<>]+)</).flatten.map(&:strip) + INDEX.scan(/(?:title|placeholder|aria-label)="([^"]+)"/).flatten
    missing = KEYS.reject { |key| shown.include?(key) }
    assert_empty missing, 'words of keys.txt that are not in index.html'
  end

  def test_the_list_of_languages_the_files_and_the_page_agree
    listed = File.read(File.join(HTML_DIR, 'i18n.js'), encoding: 'UTF-8').scan(/\['(\w\w)', '/).flatten
    assert_equal (FILES.map { |f| File.basename(f, '.js') } + ['en']).sort, listed.sort
    FILES.each { |path| assert_includes INDEX, "<script src=\"lang/#{File.basename(path)}\"></script>" }
    assert_includes INDEX, '<script src="i18n.js"></script>'
    assert_includes INDEX, 'id="language"'
  end

  def test_a_few_words_are_right
    de = table(File.join(HTML_DIR, 'lang', 'de.js'))
    assert_equal 'Einstellungen', de['Settings']
    assert_equal 'Löschen', de['Delete']
    assert_equal '设置', table(File.join(HTML_DIR, 'lang', 'zh.js'))['Settings']
    assert_equal 'Настройки', table(File.join(HTML_DIR, 'lang', 'ru.js'))['Settings']
  end
end
