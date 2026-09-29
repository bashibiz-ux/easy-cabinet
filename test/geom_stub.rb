# frozen_string_literal: true

# A tiny stand-in for the SketchUp Geom classes the plugin's pure logic touches,
# so that logic can be run and tested outside SketchUp. Only Z rotations and
# translations are supported (all this plugin ever needs). Lengths are plain
# millimetres, so `.mm` is the identity.

class Numeric
  def mm = self
end

module Geom
  Point3d = Struct.new(:x, :y, :z) do
    def initialize(x = 0, y = 0, z = 0) = super
  end
  Vector3d = Struct.new(:x, :y, :z)

  class Transformation
    attr_reader :a, :b, :c, :d, :tx, :ty, :tz

    # `offset` is an [x, y, z] array, as the plugin passes to Transformation.new.
    def initialize(offset = nil, a: 1.0, b: 0.0, c: 0.0, d: 1.0, tx: 0.0, ty: 0.0, tz: 0.0)
      tx, ty, tz = offset if offset
      @a = a
      @b = b
      @c = c
      @d = d
      @tx = tx
      @ty = ty
      @tz = tz
    end

    def self.translation(vector) = new(nil, tx: vector.x, ty: vector.y, tz: vector.z)

    def self.rotation(point, _axis, angle)
      cos = Math.cos(angle)
      sin = Math.sin(angle)
      new(nil, a: cos, b: -sin, c: sin, d: cos,
               tx: point.x - ((cos * point.x) - (sin * point.y)),
               ty: point.y - ((sin * point.x) + (cos * point.y)))
    end

    # Transformation * Transformation, or Transformation * Point3d.
    def *(other)
      if other.is_a?(Point3d)
        x, y = apply(other.x, other.y)
        return Point3d.new(x, y, other.z + tz)
      end

      Transformation.new(nil,
                         a: (a * other.a) + (b * other.c), b: (a * other.b) + (b * other.d),
                         c: (c * other.a) + (d * other.c), d: (c * other.b) + (d * other.d),
                         tx: (a * other.tx) + (b * other.ty) + tx, ty: (c * other.tx) + (d * other.ty) + ty,
                         tz: tz + other.tz)
    end

    def apply(x, y) = [(a * x) + (b * y) + tx, (c * x) + (d * y) + ty]
    def origin = Point3d.new(tx, ty, tz)
    def xaxis = Vector3d.new(a, c, 0.0)
    def yaxis = Vector3d.new(b, d, 0.0)
  end
end
