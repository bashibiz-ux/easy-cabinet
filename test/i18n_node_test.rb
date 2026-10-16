# frozen_string_literal: true

# Runs test/i18n_test.js (the language code of the panel, against a tiny stand-in for the page) when node is there.
# Run:  ruby test/i18n_node_test.rb

require 'minitest/autorun'
require 'open3'

class I18nNodeTest < Minitest::Test
  def test_the_language_code_translates_and_restores
    out, status = Open3.capture2e('node', File.expand_path('i18n_test.js', __dir__))
    assert status.success?, out
    assert_includes out, 'i18n: all good'
  rescue Errno::ENOENT
    skip 'node is not installed'
  end
end
