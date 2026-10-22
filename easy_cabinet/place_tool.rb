# frozen_string_literal: true

module EasyCabinet
  # "Insert at Point": a tool that waits for a click in the model and inserts the cabinet of the panel there (its back on the edge you click, its
  # front towards you; or turned the way it was left with no edge). The arrow keys turn it a quarter, Esc cancels. The row carries on from it
  # afterwards, like from any cabinet.
  #
  # How a click turns into a place is plain arithmetic (PlaceTool.frame): the front direction `out` of the cabinet; the row runs along z x out.
  class PlaceTool
    VK_LEFT = 37
    VK_RIGHT = 39

    # The way the front of a cabinet faces at a click: [x, y] unit vector. On an edge, the side of the edge the eye is on, else straight along x;
    # `quarters` turns it that many quarter turns.
    def self.frame(edge_dir, to_eye, quarters = 0)
      out = [1.0, 0.0]
      if edge_dir
        length = Math.hypot(edge_dir[0], edge_dir[1])
        if length > 1e-9
          out = [edge_dir[1] / length, -edge_dir[0] / length]
          out = [-out[0], -out[1]] if to_eye && ((out[0] * to_eye[0]) + (out[1] * to_eye[1])).negative?
        end
      end
      (quarters % 4).times { out = [-out[1], out[0]] }
      out
    end

    def self.start(raw, params = nil)
      model = Sketchup.active_model
      model.select_tool(new(raw, params))
      Response.ok('Click where the cabinet goes: on an edge to stand against it. The arrow keys turn it, Esc cancels.')
    end

    def initialize(raw, params = nil)
      @raw = raw
      @input = Sketchup::InputPoint.new
      @quarters = 0
      @ghost = params ? ghost_of(params) : nil
    end

    def activate
      Sketchup.status_text = 'Click where the cabinet goes (on an edge: its back stands against it). Left / Right arrow: turn. Esc: cancel.'
      # The cabinet is on view at once, in the middle of the view, and follows the cursor from its first move.
      view = Sketchup.active_model.active_view
      @input.pick(view, view.vpwidth / 2, view.vpheight / 2)
      view.invalidate
    rescue StandardError
      nil
    end

    def deactivate(view)
      view.invalidate
    end

    def onCancel(_reason, view)
      Sketchup.active_model.select_tool(nil)
      view.invalidate
    end

    def onMouseMove(_flags, x, y, view)
      @input.pick(view, x, y)
      view.invalidate
    end

    def onKeyDown(key, _repeat, _flags, view)
      @quarters += 1 if key == VK_LEFT
      @quarters -= 1 if key == VK_RIGHT
      view.invalidate
    end

    def draw(view)
      return unless @input.valid?

      @input.draw(view)
      corners = footprint(view)
      view.drawing_color = 'blue'
      view.line_width = 2
      view.draw_polyline(corners + [corners.first])
      draw_ghost(view) if @ghost
    end

    def onLButtonDown(_flags, x, y, view)
      @input.pick(view, x, y)
      return unless @input.valid?

      out = out_of(view)
      at = { 'x' => @input.position.x.to_mm, 'y' => @input.position.y.to_mm, 'out_x' => out[0], 'out_y' => out[1] }
      answer = CabinetManager.perform('insert', @raw.merge('place_at' => at))
      if answer['ok']
        LiveParts.refresh
        add_toe_kick
      end
      Sketchup.active_model.select_tool(nil)
      DialogManager.push(answer['ok'] ? 'info' : 'notice', { 'message' => answer['message'] })
    end

    private

    # A cabinet placed from the gallery stands on its toe kick (the Toe Kick fields of the panel): one is made under it unless the Toe kick switch has already made it.
    def add_toe_kick
      toe = @raw['place_toe_kick']
      return unless toe.is_a?(Hash) && @raw['cabinet_category'].to_s != 'wall' && toe['toe_kick_height'].to_f.positive?

      model = Sketchup.active_model
      placed = model.selection.to_a
      PartManager.perform('insert_toe_kick', toe) # (refused when there is one already: nothing more to do then)
      model.selection.clear
      placed.each { |item| model.selection.add(item) }
    rescue StandardError => e
      warn "[Easy Cabinet] Could not add the toe kick: #{e.message}"
    end

    # ---- the ghost: the cabinet itself, drawn at the cursor ------------------------------------------------

    # The boxes of the cabinet as edges and front faces in its own frame (x towards the front, y along the row, z up), in millimetres: { edges:, fronts:, toe: }.
    def ghost_of(params)
      layout = CabinetLayout.compute(params)
      shape = CabinetGallery.from_layout(layout, params)
      ghost = { edges: [], fronts: [], toe: [] }
      shape['parts'].each do |part|
        next if part['p'] # (a board with an outline: drawn as its outline from above)

        ox, oy, oz = part['o']
        dx, dy, dz = part['e']
        turn = part['r'].to_f * Math::PI / 180.0
        c = Math.cos(turn)
        s = Math.sin(turn)
        at = ->(x, y, z) { [ox + (x * c) - (y * s), oy + (x * s) + (y * c), oz + z] }
        low = [at.call(0, 0, 0), at.call(dx, 0, 0), at.call(dx, dy, 0), at.call(0, dy, 0)]
        high = low.map { |x, y, _| [x, y, oz + dz] }
        4.times do |i|
          ghost[:edges].push(low[i], low[(i + 1) % 4], high[i], high[(i + 1) % 4], low[i], high[i])
        end
        face = [low[1], low[2], high[2], high[1]] # the face at the high X end: the front of a door
        case part['k']
        when 'door', 'drawer' then ghost[:fronts].concat(face)
        when 'toe' then ghost[:toe].concat(face)
        end
      end
      ghost
    rescue StandardError
      nil
    end

    def draw_ghost(view)
      out = out_of(view)
      along = [-out[1], out[0]]
      origin = @input.position
      place = ->(point) { Geom::Point3d.new(origin.x + (out[0] * point[0].mm) + (along[0] * point[1].mm), origin.y + (out[1] * point[0].mm) + (along[1] * point[1].mm), origin.z + point[2].mm) }
      unless @ghost[:toe].empty?
        view.drawing_color = Sketchup::Color.new(55, 60, 70, 170)
        view.draw(GL_QUADS, @ghost[:toe].map(&place))
      end
      unless @ghost[:fronts].empty?
        view.drawing_color = Sketchup::Color.new(240, 228, 200, 150)
        view.draw(GL_QUADS, @ghost[:fronts].map(&place))
      end
      view.drawing_color = Sketchup::Color.new(60, 80, 130)
      view.line_width = 1
      view.draw(GL_LINES, @ghost[:edges].map(&place))
    end

    def out_of(view)
      edge = @input.edge
      edge_dir = nil
      if edge
        v = edge.line[1]
        edge_dir = [v.x, v.y]
      end
      eye = view.camera.eye
      here = @input.position
      self.class.frame(edge_dir, [eye.x - here.x, eye.y - here.y], @quarters)
    end

    # The footprint of the cabinet where the mouse is, to show where it will stand.
    def footprint(view)
      out = out_of(view)
      along = [-out[1], out[0]]
      depth = (@raw['depth'] || 560).to_f.mm
      width = (@raw['width'] || 600).to_f.mm
      origin = @input.position
      [[0, 0], [depth, 0], [depth, width], [0, width]].map do |d, w|
        Geom::Point3d.new(origin.x + (out[0] * d) + (along[0] * w), origin.y + (out[1] * d) + (along[1] * w), origin.z)
      end
    end
  end
end
