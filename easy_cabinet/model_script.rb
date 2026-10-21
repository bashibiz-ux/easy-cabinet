# frozen_string_literal: true

module EasyCabinet
  # What "Save Selected to My Catalog" and "Save Selected as My Handle" keep: not a SketchUp model file (.skp) but Ruby code, a .rb file that draws the model again
  # when it is run (lengths in mm). The faces (with their holes, colours and which way they face), the loose lines, the soft, smooth and hidden edges, the groups
  # and the components (each component once, however many times it is used) and the colours they use are written; pictures on faces (textures) are not.
  module ModelScript
    EXTENSION = '.rb'

    # ---- writing ---------------------------------------------------------------------------------------------------

    # Writes the model file `path` for these entities (an array of faces, edges, groups and component instances) with the name `name`.
    def self.write(path, entities, name:)
      File.write(path, source(entities, name: name), encoding: 'UTF-8')
    end

    # The Ruby code that draws `entities`.
    def self.source(entities, name:)
      writer = Writer.new
      body = writer.lines(entities, 1)
      out = ['# frozen_string_literal: true', '',
             "# #{name.to_s.gsub(/\s+/, ' ')}: a model kept by Easy Cabinet as Ruby code (lengths in mm). Running it draws the model.",
             "EasyCabinet::ModelScript.define(#{name.to_s.inspect}) do |b|"]
      writer.materials.each { |material, (rgb, alpha)| out << "  b.material(#{material.inspect}, #{rgb.inspect}, #{writer.number(alpha)})" }
      out.concat(writer.definitions)
      out.concat(body)
      out << 'end'
      "#{out.join("\n")}\n"
    end

    # Turns entities into lines of code.
    class Writer
      attr_reader :materials, :definitions

      def initialize
        @materials = {}   # name => [[r, g, b], alpha]
        @definitions = [] # the lines of the definitions of the components, each before the first thing that uses it
        @named = {}       # definition => the name it has in the code
      end

      def number(value)
        text = format('%.3f', value.to_f).sub(/0+\z/, '').sub(/\.\z/, '')
        text == '-0' ? '0' : text
      end

      def point(position)
        "[#{[position.x, position.y, position.z].map { |v| number(v.to_mm) }.join(', ')}]"
      end

      # One line of code for each thing, `depth` levels in, written for the builder called `var`.
      def lines(entities, depth, var = 'b')
        pad = '  ' * depth
        out = []
        flagged = []
        entities.each do |item|
          case item
          when Sketchup::Face
            out << "#{pad}#{var}.#{face(item)}"
            flagged.concat(item.edges)
          when Sketchup::Edge then flagged << item unless item.faces.empty?
          when Sketchup::Group then out.concat(group(item, depth, var))
          when Sketchup::ComponentInstance then out << "#{pad}#{var}.#{instance(item)}"
          end
        end
        entities.each { |item| out << "#{pad}#{var}.line(#{point(item.start.position)}, #{point(item.end.position)})" if item.is_a?(Sketchup::Edge) && item.faces.empty? }
        flags = flagged.uniq.filter_map do |edge|
          letters = (edge.soft? ? 's' : '') + (edge.smooth? ? 'm' : '') + (edge.hidden? ? 'h' : '')
          "[#{point(edge.start.position)}, #{point(edge.end.position)}, #{letters.inspect}]" unless letters.empty?
        end
        out << "#{pad}#{var}.edge_flags([#{flags.join(', ')}])" unless flags.empty?
        out
      end

      def face(item)
        parts = [loop_of(item.outer_loop)]
        holes = item.loops.reject { |l| l == item.outer_loop }.map { |l| loop_of(l) }
        parts << "holes: [#{holes.join(', ')}]" unless holes.empty?
        parts << "front: #{material(item.material).inspect}" if item.material
        parts << "back: #{material(item.back_material).inspect}" if item.back_material
        normal = item.normal
        parts << "normal: [#{[normal.x, normal.y, normal.z].map { |v| format('%.4f', v) }.join(', ')}]"
        "face(#{parts.join(', ')})"
      end

      def loop_of(loop)
        "[#{loop.vertices.map { |vertex| point(vertex.position) }.join(', ')}]"
      end

      def group(item, depth, var)
        pad = '  ' * depth
        inner = "g#{depth}"
        ["#{pad}#{var}.group(#{options_of(item)}) do |#{inner}|", *lines(item.entities.to_a, depth + 1, inner), "#{pad}end"]
      end

      def instance(item)
        "instance(#{definition_name(item.definition).inspect}, #{options_of(item)})"
      end

      def options_of(item)
        parts = []
        parts << "name: #{item.name.to_s.inspect}" unless item.name.to_s.empty?
        parts << "material: #{material(item.material).inspect}" if item.material
        parts << "transformation: #{transformation(item.transformation)}"
        parts.join(', ')
      end

      # 16 numbers, the translation (inches in SketchUp) in mm.
      def transformation(matrix)
        values = matrix.to_a.each_with_index.map { |v, i| [12, 13, 14].include?(i) ? number(v.to_mm) : number(v) }
        "[#{values.join(', ')}]"
      end

      def material(item)
        name = item.name.to_s
        @materials[name] ||= [[item.color.red, item.color.green, item.color.blue], item.alpha.to_f]
        name
      end

      # The definition of a component is written once, before it is used; its name in the code is its own, or a numbered one when two share a name.
      def definition_name(definition)
        return @named[definition] if @named.key?(definition)

        base = definition.name.to_s.empty? ? 'Component' : definition.name.to_s
        name = base
        name = "#{base} #{@named.length + 1}" while @named.value?(name)
        @named[definition] = name
        inner = lines(definition.entities.to_a, 2, 'd')
        @definitions.concat(["  b.definition(#{name.inspect}) do |d|", *inner, '  end'])
        name
      end
    end

    # ---- reading ---------------------------------------------------------------------------------------------------

    @script = nil

    # What a model file calls: the name and the code that draws it.
    def self.define(name, &block)
      @script = { name: name.to_s, block: block }
    end

    # The definition a model file makes in `model` (a model file of an earlier version, a SketchUp file, is loaded as it was).
    def self.load_definition(model, path)
      return model.definitions.load(path) unless File.extname(path.to_s).downcase == EXTENSION

      @script = nil
      Kernel.load(path)
      script = @script
      raise "#{File.basename(path)} does not draw a model." unless script

      definition = model.definitions.add(script[:name].empty? ? File.basename(path, EXTENSION) : script[:name])
      Builder.new(model, definition.entities, {}, {}).run(script[:block])
      definition
    end

    # What the code of a model file draws with: the faces, lines, groups and components of one set of entities.
    class Builder
      def initialize(model, entities, definitions, materials)
        @model = model
        @entities = entities
        @definitions = definitions
        @materials = materials
      end

      def run(block)
        block.call(self)
        self
      end

      def material(name, rgb, alpha = 1.0)
        found = @model.materials[name]
        unless found # (one the model has already is used as it is)
          found = @model.materials.add(name)
          found.color = Sketchup::Color.new(*rgb)
          found.alpha = alpha.to_f
        end
        @materials[name] = found
      end

      def point(position)
        Geom::Point3d.new(*position.map { |v| v.to_f.mm })
      end

      # A face, from its outside and its holes, the colours of its two sides and the way it faces.
      def face(outer, holes: [], front: nil, back: nil, normal: nil)
        face = @entities.add_face(outer.map { |p| point(p) })
        return nil unless face

        holes.each { |hole| @entities.add_face(hole.map { |p| point(p) })&.erase! }
        face.reverse! if normal && face.normal.dot(Geom::Vector3d.new(*normal)).negative?
        face.material = @materials[front] if front
        face.back_material = @materials[back] if back
        face
      end

      def line(from, to)
        @entities.add_line(point(from), point(to))
      end

      # Marks edges soft (s), smooth (m) or hidden (h): [[from, to, 'sh'], ...].
      def edge_flags(list)
        index = {}
        @entities.grep(Sketchup::Edge).each { |edge| index[key(edge.start.position, edge.end.position)] = edge }
        list.each do |from, to, letters|
          edge = index[key(point(from), point(to))]
          next unless edge

          edge.soft = true if letters.include?('s')
          edge.smooth = true if letters.include?('m')
          edge.hidden = true if letters.include?('h')
        end
      end

      def group(name: nil, material: nil, transformation: nil, &block)
        group = @entities.add_group
        Builder.new(@model, group.entities, @definitions, @materials).run(block)
        group.name = name if name
        group.material = @materials[material] if material
        group.transformation = to_transformation(transformation) if transformation
        group
      end

      # A component's definition, once: `definition('name') { |d| ... }`.
      def definition(name, &block)
        @definitions[name] ||= begin
          made = @model.definitions.add(name)
          Builder.new(@model, made.entities, @definitions, @materials).run(block)
          made
        end
      end

      def instance(definition_name, name: nil, material: nil, transformation: nil)
        instance = @entities.add_instance(@definitions.fetch(definition_name), to_transformation(transformation) || Geom::Transformation.new)
        instance.name = name if name
        instance.material = @materials[material] if material
        instance
      end

      private

      def to_transformation(values)
        return nil unless values

        Geom::Transformation.new(values.each_with_index.map { |v, i| [12, 13, 14].include?(i) ? v.to_f.mm : v.to_f })
      end

      def key(from, to)
        [from, to].map { |p| [p.x, p.y, p.z].map { |v| v.to_mm.round(2) } }.sort
      end
    end
  end
end
