# frozen_string_literal: true

require 'json'
require 'fileutils'

module KitchenCabinetMaster
  # Your own appliances: the model file (.skp) of an oven, microwave, fridge, sink, hob or hood, kept in your folder and used in place of the drawn
  # appliance of every cabinet that has one. The model is turned so that the side it was drawn facing (its front) looks out of the cabinet, and
  # scaled to the space the drawn appliance takes (see CabinetGenerator.apply_custom_appliances). What is kept: your folder's models/appliance_<kind>.skp
  # and appliances.json (which kinds, which side is the front).
  module MyAppliances
    KINDS = { 'oven' => 'Oven', 'micro' => 'Microwave', 'fridge' => 'Fridge / freezer', 'sink' => 'Sink and tap', 'hob' => 'Hob', 'hood' => 'Hood' }.freeze
    # How far a model is turned about the vertical so that the side it was drawn facing (-y: the front view, +x, +y, -x) faces +X, out of the cabinet.
    FRONT_TURNS = { '-y' => 90.0, '+x' => 0.0, '+y' => -90.0, '-x' => 180.0 }.freeze
    FILE = 'appliances.json'

    # ---- what is kept ------------------------------------------------------------------

    def self.root = CatalogManager.user_dir.to_s

    # { kind => { 'file', 'front', 'name' } }
    def self.meta
      path = File.join(root, FILE)
      return {} if root.empty? || !File.file?(path)

      data = JSON.parse(File.read(path))
      data.is_a?(Hash) ? data.select { |kind, entry| KINDS.key?(kind) && entry.is_a?(Hash) } : {}
    rescue JSON::ParserError, SystemCallError
      {}
    end

    def self.save_meta(data)
      FileUtils.mkdir_p(root)
      File.write(File.join(root, FILE), JSON.pretty_generate(data))
    end

    # [{ 'id', 'name', 'custom', 'file' }] for the panel.
    def self.list
      kept = meta
      KINDS.map { |id, name| { 'id' => id, 'name' => name, 'custom' => kept.key?(id), 'file' => kept.dig(id, 'name').to_s, 'front' => kept.dig(id, 'front').to_s } }
    end

    # ---- the parts of an appliance in a cabinet ------------------------------------------

    # "appliance_oven_1_door" -> "oven"; nil for what is not an appliance part.
    def self.kind_of(role)
      kind = role.to_s.split('_')[1]
      role.to_s.start_with?('appliance_') && KINDS.key?(kind) ? kind : nil
    end

    # "appliance_oven_1_door" -> "appliance_oven_1": all the parts of one appliance share it.
    def self.group_of(role)
      kind_of(role) ? role.to_s[/\Aappliance_[a-z]+_\d+/] : nil
    end

    # ---- fitting a model to a space (pure maths, mm) ----------------------------------------

    # Where a model of `size` [x, y, z] (as drawn), whose front faces `front`, goes so that it fills the box at `box_min` of `box_size`:
    # { turn: degrees about the vertical, shift: [x, y] that puts the turned model's low corner on the origin, scale: [sx, sy, sz], origin: box_min }.
    # The transformation is: move to origin * scale * shift * turn * (take the model's own low corner to zero).
    def self.fit(size, front, box_min, box_size)
      degrees = FRONT_TURNS.fetch(front.to_s, FRONT_TURNS['-y'])
      radians = degrees * Math::PI / 180.0
      cos = Math.cos(radians)
      sin = Math.sin(radians)
      corners = [[0.0, 0.0], [size[0], 0.0], [0.0, size[1]], [size[0], size[1]]].map { |x, y| [(x * cos) - (y * sin), (x * sin) + (y * cos)] }
      xs = corners.map(&:first)
      ys = corners.map(&:last)
      turned = [xs.max - xs.min, ys.max - ys.min, size[2].to_f]
      scale = [0, 1, 2].map { |i| turned[i] > 0.01 ? box_size[i] / turned[i] : 1.0 }
      { turn: degrees, shift: [-xs.min, -ys.min], scale: scale, origin: box_min }
    end

    # The bounding box [low, size] of a list of layout parts (offset and extent, mm).
    def self.box_of(parts)
      low = [0, 1, 2].map { |i| parts.map { |part| part.offset[i] }.min }
      high = [0, 1, 2].map { |i| parts.map { |part| part.offset[i] + part.extent[i] }.max }
      [low, [0, 1, 2].map { |i| high[i] - low[i] }]
    end

    # ---- the model file in the model -----------------------------------------------------------

    # The definition of your appliance of this kind (loaded once; a new file makes a new one); nil when the file is gone.
    def self.definition(model, kind, entry)
      path = File.join(root, entry['file'].to_s)
      return nil unless File.file?(path)

      name = "My Appliance #{KINDS[kind]} #{File.mtime(path).to_i}"
      existing = model.definitions[name]
      return existing if existing

      loaded = model.definitions.load(path)
      loaded.name = name
      AttributeManager.mark_managed(loaded)
      loaded
    rescue StandardError => e
      warn "[Kitchen Cabinet Master] Could not load your #{kind}: #{e.message}"
      nil
    end

    def self.size_of(definition)
      bounds = definition.bounds
      [bounds.width.to_mm, bounds.height.to_mm, bounds.depth.to_mm]
    end

    # ---- the buttons of the panel ----------------------------------------------------------------

    def self.add(raw)
      raw = {} unless raw.is_a?(Hash)
      kind = raw['kind'].to_s
      return Response.fail('Choose which appliance it is.') unless KINDS.key?(kind)
      return Response.fail('There is no folder of your own to keep the model in.') if root.empty?

      # What is selected in the model (a group, a component or loose geometry that is not a cabinet) is the appliance; with nothing selected a
      # model file is asked for.
      model = Sketchup.active_model
      items = model.selection.to_a.reject { |item| AttributeManager.cabinet?(item) || AttributeManager.part?(item) || AttributeManager.row_item?(item) }
      from = raw['file'].to_s.strip
      if items.empty? && from.empty?
        return Response.fail("Select the #{KINDS[kind].downcase} you drew in the model (a group or component), or select nothing and choose a model file.") unless defined?(UI) && UI.respond_to?(:openpanel)

        from = UI.openpanel("Choose the model file of your #{KINDS[kind].downcase}", '', 'SketchUp Model|*.skp||').to_s
        return Response.fail('No appliance was added.') if from.empty?
      end
      return Response.fail('That model file could not be found.') if items.empty? && !File.file?(from)

      single = items.length == 1 && (items.first.is_a?(Sketchup::Group) || items.first.is_a?(Sketchup::ComponentInstance)) ? items.first : nil
      front = FRONT_TURNS.key?(raw['front'].to_s) ? raw['front'].to_s : '-y'
      file = File.join('models', "appliance_#{kind}.skp")
      path = File.join(root, file)
      FileUtils.mkdir_p(File.dirname(path))
      if items.empty?
        FileUtils.cp(from, path) unless File.expand_path(from) == File.expand_path(path)
        size = measure(model, path)
      else
        size = CabinetManager.send(:write_model_file, model, items, single, path)
      end
      return Response.fail('That file is not a model that can be used as an appliance.') unless size && size.all? { |v| v > 1.0 }

      save_meta(meta.merge(kind => { 'file' => file, 'front' => front, 'name' => items.empty? ? File.basename(from, '.*').tr('_', ' ') : CabinetManager.send(:guess_name, single) }))
      refresh(model)
      Response.ok("Your #{KINDS[kind].downcase} is used now (#{size.map { |v| v.round(1) }.join(' x ')} mm as drawn, scaled to the space of the drawn one).", { 'my_appliances' => list })
    end

    def self.remove(raw)
      raw = {} unless raw.is_a?(Hash)
      kind = raw['kind'].to_s
      kept = meta
      return Response.fail("You have not uploaded a #{KINDS.fetch(kind, 'appliance').downcase}.") unless kept.key?(kind)

      FileUtils.rm_f(File.join(root, kept[kind]['file'].to_s))
      save_meta(kept.reject { |id, _| id == kind })
      refresh(Sketchup.active_model)
      Response.ok("The drawn #{KINDS[kind].downcase} is used again.", { 'my_appliances' => list })
    end

    # The size [x, y, z] in mm of the model file (it is loaded and taken out again: the model is left as it was).
    def self.measure(model, path)
      size = nil
      model.start_operation('Measure appliance', true)
      begin
        size = size_of(model.definitions.load(path))
      ensure
        model.abort_operation
      end
      size
    rescue StandardError
      nil
    end

    # Every cabinet with appliances is drawn again with what is kept now. One Undo step.
    def self.refresh(model)
      model.start_operation('My Appliances', true)
      begin
        CabinetGenerator.sync_all_appliances(model)
        model.commit_operation
      rescue StandardError
        model.abort_operation
        raise
      end
    end
  end
end
