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

    def self.start(raw)
      model = Sketchup.active_model
      model.select_tool(new(raw))
      Response.ok('Click where the cabinet goes: on an edge to stand against it. The arrow keys turn it, Esc cancels.')
    end

    def initialize(raw)
      @raw = raw
      @input = Sketchup::InputPoint.new
      @quarters = 0
    end

    def activate
      Sketchup.status_text = 'Click where the cabinet goes (on an edge: its back stands against it). Left / Right arrow: turn. Esc: cancel.'
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
    end

    def onLButtonDown(_flags, x, y, view)
      @input.pick(view, x, y)
      return unless @input.valid?

      out = out_of(view)
      at = { 'x' => @input.position.x.to_mm, 'y' => @input.position.y.to_mm, 'out_x' => out[0], 'out_y' => out[1] }
      answer = CabinetManager.perform('insert', @raw.merge('place_at' => at))
      LiveParts.refresh if answer['ok']
      Sketchup.active_model.select_tool(nil)
      DialogManager.push(answer['ok'] ? 'info' : 'notice', { 'message' => answer['message'] })
    end

    private

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
