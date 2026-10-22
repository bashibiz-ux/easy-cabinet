# frozen_string_literal: true

require 'digest'
require 'json'

module EasyCabinet
  # The monthly support goal. Easy Cabinet is kept alive by donations: every month has a target (1000 USD to begin with). The people who use the extension see
  # how much of it has been reached; when the month's target is not reached by the end of a grace period (the first days of the month), the extension stops
  # until it is, and says so with a Donate button. The author is not held to this: see `developer?`.
  #
  # Where the amount reached comes from: a small JSON file the author keeps on the web (the `status_url` of easy_cabinet/config.json), written by hand or by a
  # script from the donation page:  { "month": "2026-11", "target": 1000, "raised": 372.5, "currency": "USD" }
  # Nothing about the user is sent: the file is only read. Whatever goes wrong (no connection, a damaged file, a file of another month) the extension keeps
  # working: it is only ever stopped by a status that says the target is not reached.
  #
  # This is a request, not a lock: the code of an extension is open and can be changed by whoever wants to.
  module SupportStatus
    CONFIG_PATH = File.join(__dir__, 'config.json')
    SECTION = 'EasyCabinet'
    CACHE_KEY = 'support_status_text' # (kept as base64: SketchUp cannot read back a text with quotes in it)
    REFRESH_SECONDS = 6 * 3600
    STALE_DAYS = 14 # a status older than this (it could not be refreshed) is not trusted
    DEVELOPER_FILE = 'developer.key'
    # What still works while the extension is stopped: opening the panel (to say why), the Donate button, checking again, feedback.
    ALLOWED_WHEN_LOCKED = %w[init get_support refresh_support open_donation send_feedback load_presets].freeze
    DEFAULTS = { 'status_url' => '', 'monthly_target' => 1000.0, 'currency' => 'USD', 'grace_days' => 10, 'developer_hash' => '' }.freeze

    # The settings of config.json, each checked (a missing or odd value gives the default).
    def self.settings(path = CONFIG_PATH)
      stored = begin
        JSON.parse(File.read(path, encoding: 'UTF-8'))
      rescue StandardError
        {}
      end
      stored = {} unless stored.is_a?(Hash)
      target = stored['monthly_target'].to_f
      grace = stored['grace_days'].to_i
      {
        'status_url' => stored['status_url'].to_s.strip,
        'monthly_target' => target.positive? && target <= 10_000_000 ? target : DEFAULTS['monthly_target'],
        'currency' => stored['currency'].to_s.strip.empty? ? DEFAULTS['currency'] : stored['currency'].to_s.strip[0, 6],
        'grace_days' => stored['grace_days'].nil? || grace.negative? || grace > 28 ? DEFAULTS['grace_days'] : grace,
        'developer_hash' => stored['developer_hash'].to_s.strip.downcase,
        'donation_url' => stored['donation_url'].to_s.strip
      }
    end

    # What the panel shows and what stops the extension, worked out from the settings, the last status that was read (`cache`: { 'status' =>, 'fetched_at' => }),
    # the time and whether this is the author. Pure: no SketchUp calls.
    #   mode      'off' (no status address set up), 'developer', 'unknown' (no status to go by), 'funded', 'grace' (not reached yet, still working) or 'locked'
    def self.evaluate(settings, cache, now, developer)
      state = { 'mode' => 'off', 'locked' => false, 'currency' => settings['currency'], 'target' => settings['monthly_target'], 'raised' => 0.0, 'percent' => 0,
                'month' => now.strftime('%Y-%m'), 'grace_days' => settings['grace_days'], 'donate_url' => settings['donation_url'].to_s, 'message' => '' }
      return state.merge('mode' => 'developer') if developer
      return state if settings['status_url'].to_s.empty?

      status = cache.is_a?(Hash) ? cache['status'] : nil
      stale = status.nil? || (now.to_f - cache['fetched_at'].to_f) > STALE_DAYS * 86_400
      return state.merge('mode' => 'unknown') if stale || status['month'] != state['month']

      target = status['target'].to_f.positive? ? status['target'].to_f : settings['monthly_target']
      raised = [status['raised'].to_f, 0.0].max
      currency = status['currency'].to_s.empty? ? settings['currency'] : status['currency'].to_s
      met = raised >= target
      in_grace = now.day <= settings['grace_days']
      mode = met ? 'funded' : (in_grace ? 'grace' : 'locked')
      money = ->(value) { "#{currency} #{value == value.round ? value.round : format('%.2f', value)}" }
      message = case mode
                when 'funded' then "Thank you! This month's target of #{money.call(target)} has been reached (#{money.call(raised)})."
                when 'grace' then "This month's target is #{money.call(target)} and we have reached #{money.call(raised)}. Please donate to keep Easy Cabinet alive. " \
                                  "It keeps working until day #{settings['grace_days']} of the month; after that it stops until the target is reached."
                else "The monthly target is #{money.call(target)} and we have reached #{money.call(raised)}. Please donate to keep Easy Cabinet alive. " \
                     'It works again as soon as the target is reached.'
                end
      state.merge('mode' => mode, 'locked' => mode == 'locked', 'currency' => currency, 'target' => target, 'raised' => raised,
                  'percent' => [(raised / target * 100.0).floor, 100].min, 'message' => message)
    end

    # The status of right now.
    def self.state(now = Time.now.utc)
      conf = settings
      evaluate(conf, read_cache, now, developer?(conf))
    end

    def self.locked? = state['locked'] == true

    # For a menu command or a tool: true when it may go on; when the extension is stopped, says why and returns false.
    def self.working?
      current = state
      return true unless current['locked']

      UI.messagebox(current['message'])
      false
    end

    # The author: a file developer.key in the folder of the user's own data of Easy Cabinet whose text has the SHA-256 written in config.json. Only the author
    # has that text (the file is not part of the extension).
    def self.developer?(conf = settings)
      hash = conf['developer_hash'].to_s
      return false if hash.empty?

      root = CatalogManager.send(:user_root)
      path = root && File.join(root, DEVELOPER_FILE)
      !!path && File.file?(path) && Digest::SHA256.hexdigest(File.read(path, encoding: 'UTF-8').strip) == hash
    rescue StandardError
      false
    end

    # What the status file says, or nil when it is not a status: { 'month', 'target', 'raised', 'currency' }.
    def self.parse(text)
      data = JSON.parse(text.to_s)
      return nil unless data.is_a?(Hash) && data['month'].to_s.match?(/\A\d{4}-\d{2}\z/) && data['raised'].is_a?(Numeric) && data['raised'] >= 0

      out = { 'month' => data['month'], 'raised' => data['raised'].to_f }
      out['target'] = data['target'].to_f if data['target'].is_a?(Numeric) && data['target'].positive? && data['target'] <= 10_000_000
      out['currency'] = data['currency'].to_s.strip[0, 6] if data['currency'].is_a?(String)
      out
    rescue JSON::ParserError
      nil
    end

    # Reads the status file again (at most every few hours unless `force`), in the background; the panel is told when it has changed. => whether a request went out.
    def self.refresh(force = false)
      url = settings['status_url']
      return false unless url.start_with?('https://') && defined?(Sketchup::Http)

      cache = read_cache
      return false if !force && cache && (Time.now.to_f - cache['fetched_at'].to_f) < REFRESH_SECONDS
      return false if @fetching

      @fetching = true
      request = Sketchup::Http::Request.new(url, Sketchup::Http::GET)
      request.start do |_request, response|
        @fetching = false
        status = response.status_code == 200 ? parse(response.body) : nil
        if status
          write_cache('status' => status, 'fetched_at' => Time.now.to_f)
          DialogManager.push('support', state) if defined?(DialogManager)
        end
      rescue StandardError => e
        @fetching = false
        warn "[Easy Cabinet] Could not read the support status: #{e.message}"
      end
      true
    rescue StandardError => e
      @fetching = false
      warn "[Easy Cabinet] Could not ask for the support status: #{e.message}"
      false
    end

    # Once, a little after SketchUp has started (the status is read without holding anything up).
    def self.start
      UI.start_timer(8.0, false) { refresh }
    rescue StandardError
      nil
    end

    def self.read_cache
      text = Sketchup.read_default(SECTION, CACHE_KEY, '').to_s
      return nil if text.empty?

      data = JSON.parse(text.unpack1('m'))
      data.is_a?(Hash) && data['status'].is_a?(Hash) ? data : nil
    rescue StandardError, ScriptError
      nil
    end
    private_class_method :read_cache

    def self.write_cache(data)
      Sketchup.write_default(SECTION, CACHE_KEY, [JSON.generate(data)].pack('m0'))
    end
    private_class_method :write_cache
  end
end
