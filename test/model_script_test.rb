# frozen_string_literal: true

# The models that "Save Selected to My Catalog" and "Save Selected as My Handle" keep are Ruby files that draw them (ModelScript), not SketchUp files. SketchUp is faked:
# a model is written as code, the file is run, and what it draws is looked at. Run:  ruby test/model_script_test.rb

require 'minitest/autorun'
require 'tmpdir'
require_relative 'geom_stub'

module Geom
  class Vector3d
    def dot(other) = (x * other.x) + (y * other.y) + (z * other.z)
  end
end

module Sketchup
  Color = Struct.new(:red, :green, :blue)
  Material = Struct.new(:name, :color, :alpha) do
    def color=(value)
      self[:color] = value
    end
  end
  Vertex = Struct.new(:position)
  Loop = Struct.new(:vertices)
  class Edge; end
  class Face; end
  class Group; end
  class ComponentInstance; end
end

require File.expand_path('../easy_cabinet/model_script', __dir__)

# ---- what is written: things that look like SketchUp's ----------------------------------------------------------------
class FakeFace < Sketchup::Face
  attr_reader :outer_loop, :loops, :material, :back_material, :normal, :edges

  def initialize(outer, holes: [], material: nil, normal: [0, 0, 1], edges: [])
    super()
    @outer_loop = make(outer)
    @loops = [@outer_loop] + holes.map { |h| make(h) }
    @material = material
    @back_material = nil
    @normal = Geom::Vector3d.new(*normal)
    @edges = edges
  end

  def make(points) = Sketchup::Loop.new(points.map { |p| Sketchup::Vertex.new(Geom::Point3d.new(*p)) })
end

class FakeEdge < Sketchup::Edge
  attr_reader :start, :end, :faces

  def initialize(from, to, faces: [], soft: false)
    super()
    @start = Sketchup::Vertex.new(Geom::Point3d.new(*from))
    @end = Sketchup::Vertex.new(Geom::Point3d.new(*to))
    @faces = faces
    @soft = soft
  end

  def soft? = @soft
  def smooth? = false
  def hidden? = false
end

class FakeDefinition
  attr_reader :name, :entities

  def initialize(name, entities) = (@name = name; @entities = entities)
end

class FakeGroup < Sketchup::Group
  attr_reader :name, :material, :transformation, :entities

  def initialize(name, entities) = (super(); @name = name; @material = nil; @transformation = Geom::Transformation.new([10.0, 0.0, 0.0]); @entities = FakeList.new(entities))
end

class FakeInstance < Sketchup::ComponentInstance
  attr_reader :definition, :name, :material, :transformation

  def initialize(definition, name, at) = (super(); @definition = definition; @name = name; @material = nil; @transformation = Geom::Transformation.new(at))
end

class FakeList
  def initialize(items) = @items = items
  def to_a = @items
end

# ---- what is read: a model that records what is drawn into it ----------------------------------------------------------------
class DrawnFace
  attr_reader :points, :holes
  attr_accessor :material, :back_material

  def initialize(points) = (@points = points; @holes = [])
  def normal = Geom::Vector3d.new(0, 0, 1)
  def reverse! = (@reversed = true)
  def erase! = nil
end

class Drawn
  attr_reader :faces, :lines, :groups, :instances, :flags
  attr_accessor :name, :material, :transformation

  def initialize = (@faces = []; @lines = []; @groups = []; @instances = []; @flags = nil)

  def add_face(points) = DrawnFace.new(points).tap { |face| @faces << face }
  def add_line(from, to) = @lines << [from, to]
  def add_group = Drawn.new.tap { |group| @groups << group }
  def add_instance(definition, transformation) = Drawn.new.tap { |made| made.transformation = transformation; @instances << [definition, made] }
  def grep(_kind) = []
  def entities = self
end

class FakeModel
  attr_reader :made, :materials

  def initialize = (@made = []; @materials = Materials.new)

  def definitions = self

  def add(name) = Drawn.new.tap { |definition| definition.name = name; @made << definition }

  class Materials
    attr_reader :list

    def initialize = @list = {}
    def [](name) = @list[name]
    def add(name) = @list[name] = Sketchup::Material.new(name, nil, 1.0).tap { |m| def m.alpha=(v); end }
  end
end

class ModelScriptTest < Minitest::Test
  EC = EasyCabinet

  def red = Sketchup::Material.new('Red', Sketchup::Color.new(200, 20, 20), 1.0)

  def source_of(entities) = EC::ModelScript.source(entities, name: 'A test model')

  def test_a_face_with_a_hole_and_a_colour_is_written_as_code
    face = FakeFace.new([[0, 0, 0], [100, 0, 0], [100, 50, 0], [0, 50, 0]], holes: [[[10, 10, 0], [20, 10, 0], [20, 20, 0], [10, 20, 0]]], material: red)
    code = source_of([face])
    assert_includes code, "EasyCabinet::ModelScript.define(\"A test model\") do |b|"
    assert_includes code, 'b.material("Red", [200, 20, 20], 1)'
    assert_includes code, 'b.face([[0, 0, 0], [100, 0, 0], [100, 50, 0], [0, 50, 0]], holes: [[[10, 10, 0], [20, 10, 0], [20, 20, 0], [10, 20, 0]]], front: "Red"'
    assert_includes code, 'normal: [0.0000, 0.0000, 1.0000]'
    refute_match(/\.skp/, code)
  end

  def test_loose_lines_and_the_soft_edges_of_a_face_are_written
    soft = FakeEdge.new([0, 0, 0], [100, 0, 0], faces: [:one], soft: true)
    face = FakeFace.new([[0, 0, 0], [100, 0, 0], [0, 50, 0]], edges: [soft])
    loose = FakeEdge.new([0, 0, 10], [0, 0, 90])
    code = source_of([face, loose])
    assert_includes code, 'b.line([0, 0, 10], [0, 0, 90])'
    assert_includes code, 'b.edge_flags([[[0, 0, 0], [100, 0, 0], "s"]])'
  end

  def test_a_component_used_twice_is_written_once_and_the_transformation_is_in_mm
    inside = FakeFace.new([[0, 0, 0], [10, 0, 0], [0, 10, 0]])
    definition = FakeDefinition.new('Knob', FakeList.new([inside]))
    code = source_of([FakeInstance.new(definition, 'Handle', [30.0, 0.0, 0.0]), FakeInstance.new(definition, '', [60.0, 0.0, 0.0])])
    assert_equal 1, code.scan('b.definition("Knob")').length
    assert_equal 2, code.scan('b.instance("Knob"').length
    assert_includes code, 'name: "Handle"'
    assert_includes code, '30, 0, 0, 1]'
    assert_operator code.index('b.definition'), :<, code.index('b.instance'), 'the component is defined before it is used'
  end

  def test_a_group_is_written_with_what_is_in_it
    group = FakeGroup.new('Grip', [FakeFace.new([[0, 0, 0], [10, 0, 0], [0, 10, 0]])])
    code = source_of([group])
    assert_includes code, 'b.group(name: "Grip", transformation: ['
    assert_includes code, '  g1.face([[0, 0, 0], [10, 0, 0], [0, 10, 0]]'
  end

  def test_the_file_draws_the_model_again_when_it_is_run
    inside = FakeFace.new([[0, 0, 0], [10, 0, 0], [0, 10, 0]])
    definition = FakeDefinition.new('Knob', FakeList.new([inside]))
    face = FakeFace.new([[0, 0, 0], [100, 0, 0], [100, 50, 0], [0, 50, 0]], holes: [[[10, 10, 0], [20, 10, 0], [20, 20, 0], [10, 20, 0]]], material: red)
    entities = [face, FakeEdge.new([0, 0, 10], [0, 0, 90]), FakeGroup.new('Grip', [FakeFace.new([[0, 0, 0], [5, 0, 0], [0, 5, 0]])]),
                FakeInstance.new(definition, 'Handle', [30.0, 0.0, 0.0]), FakeInstance.new(definition, '', [60.0, 0.0, 0.0])]
    Dir.mktmpdir do |dir|
      path = File.join(dir, 'model.rb')
      EC::ModelScript.write(path, entities, name: 'A test model')
      assert File.file?(path)
      model = FakeModel.new
      made = EC::ModelScript.load_definition(model, path)
      assert_equal 'A test model', made.name
      assert_equal [[0, 0, 0], [100, 0, 0], [100, 50, 0], [0, 50, 0]].map { |p| Geom::Point3d.new(*p) }, made.faces.first.points
      assert_equal 1, made.lines.length
      assert_equal 1, made.groups.length
      assert_equal 'Grip', made.groups.first.name
      assert_equal 1, made.groups.first.faces.length
      assert_equal 2, made.instances.length
      assert_equal 1, (model.made.map(&:name) - ['A test model']).length, 'the component was made once'
      assert_equal made.instances.first[0], made.instances.last[0], 'both are the same component'
      assert_equal 'Handle', made.instances.first[1].name
      assert_equal 30.0, made.instances.first[1].transformation.tx
      assert_equal [200, 20, 20], model.materials.list['Red'].color.to_a
    end
  end

  def test_a_file_that_draws_nothing_is_refused
    Dir.mktmpdir do |dir|
      path = File.join(dir, 'empty.rb')
      File.write(path, "# nothing\n")
      assert_raises(RuntimeError) { EC::ModelScript.load_definition(FakeModel.new, path) }
    end
  end
end
