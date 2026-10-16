# frozen_string_literal: true

require 'erb'

module KitchenCabinetMaster
  # The Feedback button: a comment, suggestion or problem report from the user of the extension, written in the panel and sent from the user's own
  # mail program (a mail is opened with the address, the subject and the text filled in; nothing is sent from here by itself).
  module FeedbackManager
    FEEDBACK_EMAIL = 'bashibiz@gmail.com' # where the feedback goes
    KINDS = { 'comment' => 'Comment', 'suggestion' => 'Suggestion', 'problem' => 'Problem', 'praise' => 'Praise' }.freeze
    MAX_MESSAGE = 1500 # characters (a mail link can only carry so much)

    # Where the feedback can be sent from: the mail program of the computer, or the web page of a web mail that writes it (for those who have no mail
    # program set up). { 'mailto' => url, 'gmail' => url, 'outlook' => url, 'yahoo' => url }
    def self.links(subject, body)
      to = ERB::Util.url_encode(FEEDBACK_EMAIL)
      s = ERB::Util.url_encode(subject)
      b = ERB::Util.url_encode(body)
      {
        'mailto' => "mailto:#{FEEDBACK_EMAIL}?subject=#{s}&body=#{b}",
        'gmail' => "https://mail.google.com/mail/?view=cm&fs=1&to=#{to}&su=#{s}&body=#{b}",
        'outlook' => "https://outlook.live.com/mail/0/deeplink/compose?to=#{to}&subject=#{s}&body=#{b}",
        'yahoo' => "https://compose.mail.yahoo.com/?to=#{to}&subject=#{s}&body=#{b}"
      }
    end

    # => [{ links }, subject, body, nil] or [nil, nil, nil, error message]
    def self.compose(raw, extension_version: nil, sketchup_version: nil)
      raw = {} unless raw.is_a?(Hash)
      message = raw['message'].to_s.strip
      return [nil, nil, nil, 'Write your feedback first.'] if message.empty?
      return [nil, nil, nil, "Please keep it under #{MAX_MESSAGE} characters (it is #{message.length})."] if message.length > MAX_MESSAGE

      kind = KINDS.fetch(raw['kind'].to_s, KINDS['comment'])
      reply = raw['reply_to'].to_s.strip
      body = +message
      body << "\n\nReply to: #{reply}" unless reply.empty?
      details = []
      details << "Kitchen Cabinet Master #{extension_version}" if extension_version && raw['include_info'] != false
      details << "SketchUp #{sketchup_version}" if sketchup_version && raw['include_info'] != false
      body << "\n\n--\n#{details.join(', ')}" unless details.empty?
      subject = "Kitchen Cabinet Master feedback: #{kind}"
      [links(subject, body), subject, body, nil]
    end

    # The mail program's link only (see compose): => [url, nil] or [nil, error message]
    def self.mailto(raw, extension_version: nil, sketchup_version: nil)
      found, _subject, _body, problem = compose(raw, extension_version: extension_version, sketchup_version: sketchup_version)
      problem ? [nil, problem] : [found['mailto'], nil]
    end

    # `via`: 'mailto' (the mail program), 'gmail', 'outlook' or 'yahoo' (their web pages, opened in the browser) or 'text' (nothing is opened:
    # the text and the address come back, for the panel to copy).
    def self.perform(raw)
      raw = {} unless raw.is_a?(Hash)
      version = defined?(EXTENSION_VERSION) ? EXTENSION_VERSION : nil
      found, subject, body, problem = compose(raw, extension_version: version, sketchup_version: (Sketchup.version if defined?(Sketchup) && Sketchup.respond_to?(:version)))
      return Response.fail(problem) if problem

      via = raw['via'].to_s
      return Response.ok('The feedback is ready to copy.', { 'text' => "To: #{FEEDBACK_EMAIL}\nSubject: #{subject}\n\n#{body}" }) if via == 'text'

      UI.openURL(found.fetch(via, found['mailto']))
      names = { 'gmail' => 'Gmail', 'outlook' => 'Outlook.com', 'yahoo' => 'Yahoo Mail' }
      Response.ok(names[via] ? "#{names[via]} opened in your browser with the feedback ready: sign in if it asks, then press Send. Thank you!" : 'Your mail program opened with the feedback ready: press Send there. Thank you!')
    end
  end
end
