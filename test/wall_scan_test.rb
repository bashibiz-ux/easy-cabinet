# frozen_string_literal: true

# How SnapManager finds the walls in a model (collect_walls / wall_from), and the
# whole snap decision in one piece, using fake faces and groups. Run:
#   ruby test/wall_scan_test.rb

require 'minitest/autorun'
require_relative 'geom_stub'

module Sketchup
  class EntitiesObserver; end
  class ToolsObserver; end
  class AppObserver; end
  class ComponentInstance; end

  Layer = Struct.new(:visible?)

  class Face
    attr_reader :normal, :outer_loop

    def initialize(normal, points)
      @normal = normal
      @outer_loop = Struct.new(:vertices).new(points.map { |p| Struct.new(:position).new(p) })
    end
  end

  class Group
    attr_reader :entities, :transformation, :layer

    def initialize(entities, transformation = Geom::Transformation.new, hidden: false, layer_visible: true)
      @entities = entities
      @transformation = transformation
      @hidden = hidden
      @layer = Layer.new(layer_visible)
    end

    def hidden? = @hidden
    def attribute_dictionary(_name, _create = false) = nil
  end
end

module KitchenCabinetMaster
  module AttributeManager
    def self.cabinet?(entity) = entity.respond_to?(:cabinet_marker)
    def self.part?(_entity) = false
  end
end

require_relative '../kitchen_cabinet_master/snap_manager'

class WallScanTest < Minitest::Test
  Snap = KitchenCabinetMaster::SnapManager
  P = Geom::Point3d
  Group = Sketchup::Group

  # A vertical wall face along Y at X = x (its surface normal is X), 4 m long and 2.4 m tall.
  def wall_face(x, from: 0.0, to: 4000.0, height: 2400.0, normal: Geom::Vector3d.new(1, 0, 0))
    Sketchup::Face.new(normal, [P.new(x, from, 0), P.new(x, to, 0), P.new(x, to, height), P.new(x, from, height)])
  end

  Model = Struct.new(:entities)

  def walls(entities, skip = nil) = Snap.send(:collect_walls, Model.new(entities), skip)

  def test_a_tall_vertical_face_is_a_wall
    found = walls([wall_face(0.0)])
    assert_equal 1, found.length
    assert_equal [1.0, 0.0], found.first[:normal]
    assert_equal [0.0, 2400.0], found.first[:z]
    assert_equal [0.0, 0.0], found.first[:points].first
  end

  def test_the_face_can_face_either_way
    away = wall_face(0.0, normal: Geom::Vector3d.new(-1, 0, 0))
    assert_equal [-1.0, 0.0], walls([away]).first[:normal]
    # ... and the maths accepts both sides of it
    mover = { f: [1.0, 0.0], origin: [60.0, 1000.0], t: [1000.0, 1600.0], z: [100.0, 880.0] }
    assert_in_delta(-60.0, Snap.wall_delta(mover, walls([away]), 200.0)[0], 1e-9)
  end

  def test_floors_ceilings_and_small_faces_are_not_walls
    floor = Sketchup::Face.new(Geom::Vector3d.new(0, 0, 1), [P.new(0, 0, 0), P.new(4000, 0, 0), P.new(4000, 3000, 0), P.new(0, 3000, 0)])
    low = wall_face(0.0, height: 600.0)                # a plinth, not a wall
    narrow = wall_face(0.0, from: 0.0, to: 200.0)      # a post
    assert_empty walls([floor, low, narrow])
  end

  def test_walls_inside_groups_and_components_are_found_and_moved_into_place
    room = Group.new([wall_face(0.0)], Geom::Transformation.translation(Geom::Vector3d.new(1000.0, 0.0, 0.0)))
    found = walls([room])
    assert_equal 1, found.length
    assert_equal 1000.0, found.first[:points].first[0], 'the group\'s own position is applied'
  end

  def test_a_rotated_room_gives_a_rotated_wall
    turn = Geom::Transformation.rotation(Geom::Point3d.new(0, 0, 0), Geom::Vector3d.new(0, 0, 1), Math::PI / 2)
    found = walls([Group.new([wall_face(0.0)], turn)])
    assert_in_delta 0.0, found.first[:normal][0], 1e-9
    assert_in_delta 1.0, found.first[:normal][1], 1e-9
  end

  def test_hidden_groups_and_our_own_cabinets_are_not_walls
    hidden = Group.new([wall_face(0.0)], hidden: true)
    off_layer = Group.new([wall_face(0.0)], layer_visible: false)
    ours = Group.new([wall_face(0.0)])
    ours.define_singleton_method(:cabinet_marker) { true }
    assert_empty walls([hidden, off_layer, ours])
  end

  def test_the_item_being_moved_is_skipped
    mine = Group.new([wall_face(0.0)])
    assert_empty walls([mine], mine)
  end

  def test_nesting_is_limited
    deep = wall_face(0.0)
    4.times { deep = Group.new([deep]) }
    assert_empty walls([deep]), 'four levels down is beyond what is scanned'
    shallow = Group.new([Group.new([Group.new([wall_face(0.0)])])])
    assert_equal 1, walls([shallow]).length, 'three levels is fine'
  end
end
