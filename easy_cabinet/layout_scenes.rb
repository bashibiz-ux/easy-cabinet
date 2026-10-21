# frozen_string_literal: true

module EasyCabinet
  # The scenes a kitchen drawing in LayOut is made from: a Plan (seen from above, the roof hidden) and an Elevation for each wall the cabinets stand against (seen straight
  # at the wall, the roof and the walls hidden so that nothing is in the way), all in parallel projection. In LayOut insert the model and choose a scene for each page.
  # The room is the one of Build Room; without one, the space the cabinets take up.
  module LayoutScenes
    MARGIN = 300.0  # mm round what is drawn
    ASPECT = 1.5    # width / height of the frame a drawing is put in (LayOut fits the width to its frame; the height of the view is what is set here)
    WALLS = { 'south' => { direction: [0.0, -1.0, 0.0], side: :min_y }, 'north' => { direction: [0.0, 1.0, 0.0], side: :max_y },
              'west' => { direction: [-1.0, 0.0, 0.0], side: :min_x }, 'east' => { direction: [1.0, 0.0, 0.0], side: :max_x } }.freeze

    # The scenes for a room or a space `box` ({ x0:, y0:, x1:, y1: } in mm) that is `height` mm high: [{ name:, eye:, target:, up:, height:, hide: [tag kinds] }] (mm).
    # `walls` are the walls to draw an elevation of (names in WALLS); without them, all four.
    def self.scenes(box, height, walls = nil)
      walls = WALLS.keys if walls.nil? || walls.empty?
      cx = (box[:x0] + box[:x1]) / 2.0
      cy = (box[:y0] + box[:y1]) / 2.0
      dx = box[:x1] - box[:x0]
      dy = box[:y1] - box[:y0]
      list = [{ name: 'Plan', eye: [cx, cy, height + 5000.0], target: [cx, cy, 0.0], up: [0.0, 1.0, 0.0], height: [dy, dx / ASPECT].max + (2 * MARGIN), hide: %w[Roof] }]
      WALLS.keys.select { |name| walls.include?(name) }.each do |name|
        direction = WALLS[name][:direction]
        across = direction[0].zero? ? dx : dy # (the length of the wall)
        deep = direction[0].zero? ? dy : dx   # (how far the room goes towards it)
        at = { 'south' => [cx, box[:y0]], 'north' => [cx, box[:y1]], 'west' => [box[:x0], cy], 'east' => [box[:x1], cy] }[name]
        target = [at[0], at[1], height / 2.0]
        eye = [0, 1, 2].map { |i| target[i] - (direction[i] * (deep + 3000.0)) } # (outside the room, behind the wall that is hidden)
        list << { name: "Elevation #{name.capitalize}", eye: eye, target: target, up: [0.0, 0.0, 1.0], height: [height + (2 * MARGIN), across / ASPECT].max + MARGIN, hide: %w[Roof Walls] }
      end
      list
    end

    # The walls the backs of the cabinets stand against: ['south', ...] (none: all of them).
    def self.walls_with_backs(backs)
      WALLS.select { |_, wall| backs && backs[wall[:side]] }.keys
    end

    # ---- SketchUp -----------------------------------------------------------------------------

    def self.create(_raw = nil)
      model = Sketchup.active_model
      plan = RoomShell.plan_of(model)
      box, height, walls = plan ? [plan, plan[:height].to_f, walls_with_backs(plan[:backs])] : [cabinet_box(model), cabinet_height(model), nil]
      return Response.fail('There is nothing to draw yet: build a room (Room card) or put cabinets in the model first.') unless box

      specs = scenes(box, height, walls)
      view = model.active_view
      was = view.camera
      before = [was.eye, was.target, was.up, was.perspective?, was.perspective? ? was.fov : was.height]
      model.start_operation('Create LayOut Scenes', true)
      begin
        specs.each { |spec| add_scene(model, view, spec) }
        restore(view, before)
        model.commit_operation
      rescue StandardError
        model.abort_operation
        raise
      end
      Response.ok("#{specs.length} scenes for LayOut: #{specs.map { |s| s[:name] }.join(', ')}. In LayOut: File > Insert the model, then choose a scene on each page.")
    end

    def self.add_scene(model, view, spec)
      hidden = spec[:hide].filter_map { |kind| model.layers[RoomShell::TAGS[kind]] }.select(&:visible?)
      hidden.each { |layer| layer.visible = false }
      camera = Sketchup::Camera.new(point(spec[:eye]), point(spec[:target]), Geom::Vector3d.new(*spec[:up]))
      camera.perspective = false
      camera.height = spec[:height].mm
      view.camera = camera
      existing = model.pages[spec[:name]]
      model.pages.erase(existing) if existing
      model.pages.add(spec[:name])
      hidden.each { |layer| layer.visible = true } # (the model is left as it was; the scene remembers what it hid)
    end
    private_class_method :add_scene

    def self.restore(view, before)
      eye, target, up, perspective, size = before
      camera = Sketchup::Camera.new(eye, target, up)
      camera.perspective = perspective
      perspective ? camera.fov = size : camera.height = size
      view.camera = camera
    end
    private_class_method :restore

    def self.point(values) = Geom::Point3d.new(*values.map { |v| v.mm })

    # The space the cabinets take up when there is no room: { x0:, y0:, x1:, y1: } in mm, or nil.
    def self.cabinet_box(model)
      boxes = cabinets(model).map { |item| item.bounds }
      return nil if boxes.empty?

      { x0: boxes.map { |b| b.min.x.to_mm }.min, y0: boxes.map { |b| b.min.y.to_mm }.min, x1: boxes.map { |b| b.max.x.to_mm }.max, y1: boxes.map { |b| b.max.y.to_mm }.max }
    end
    private_class_method :cabinet_box

    def self.cabinet_height(model)
      [cabinets(model).map { |item| item.bounds.max.z.to_mm }.max.to_f, 2400.0].max
    end
    private_class_method :cabinet_height

    def self.cabinets(model)
      model.entities.grep(Sketchup::ComponentInstance).select { |item| AttributeManager.cabinet?(item) }
    end
    private_class_method :cabinets
  end
end
