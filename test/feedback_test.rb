# frozen_string_literal: true

# The Feedback button: the mail that is opened. Run:  ruby test/feedback_test.rb

require 'minitest/autorun'
require 'uri'
require_relative '../kitchen_cabinet_master/feedback_manager'

class FeedbackTest < Minitest::Test
  FM = KitchenCabinetMaster::FeedbackManager

  def mail(raw, opts = {}) = FM.mailto(raw, **opts)

  def test_an_empty_message_is_refused
    assert_equal [nil, 'Write your feedback first.'], mail({ 'message' => '   ' })
  end

  def test_a_message_that_is_too_long_is_refused
    url, problem = mail({ 'message' => 'x' * 1600 })
    assert_nil url
    assert_match(/under 1500/, problem)
  end

  def test_the_mail_has_the_address_the_kind_in_the_subject_and_the_text_in_the_body
    url, = mail({ 'kind' => 'suggestion', 'message' => 'A hob with 5 rings & a hood' }, extension_version: '1.51.0', sketchup_version: '24.0')
    assert url.start_with?("mailto:#{FM::FEEDBACK_EMAIL}?")
    query = URI.decode_www_form(url.split('?', 2).last.gsub('+', '%2B')).to_h
    assert_equal 'Kitchen Cabinet Master feedback: Suggestion', query['subject']
    assert_includes query['body'], 'A hob with 5 rings & a hood'
    assert_includes query['body'], 'Kitchen Cabinet Master 1.51.0, SketchUp 24.0'
  end

  def test_the_version_lines_and_the_reply_address_are_optional
    url, = mail({ 'message' => 'Hello', 'include_info' => false, 'reply_to' => 'me@example.com' }, extension_version: '1.51.0')
    body = URI.decode_www_form(url.split('?', 2).last.gsub('+', '%2B')).to_h['body']
    refute_includes body, '1.51.0'
    assert_includes body, 'Reply to: me@example.com'
  end

  def test_an_unknown_kind_is_a_comment
    url, = mail({ 'kind' => 'x', 'message' => 'Hi' })
    assert_includes url, 'Comment'
  end
  def test_web_mail_links_carry_the_address_the_subject_and_the_text
    links, subject, body, problem = FM.compose({ 'message' => 'Nice & fast', 'kind' => 'praise' })
    assert_nil problem
    assert_equal %w[gmail mailto outlook yahoo], links.keys.sort
    assert_equal 'Kitchen Cabinet Master feedback: Praise', subject
    assert_includes body, 'Nice & fast'
    assert links['gmail'].start_with?('https://mail.google.com/mail/?view=cm')
    assert_includes links['gmail'], 'to=bashibiz%40gmail.com'
    assert_includes links['outlook'], 'outlook.live.com'
    assert_includes links['yahoo'], 'compose.mail.yahoo.com'
    assert_includes links['gmail'], 'Nice%20%26%20fast', 'the & is written out, so it does not end the text'
  end

  def test_no_web_link_is_made_for_an_empty_message
    assert_equal 'Write your feedback first.', FM.compose({ 'message' => '' }).last
  end
end