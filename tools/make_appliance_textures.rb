# frozen_string_literal: true

# Writes the pictures the appliances' materials use (easy_cabinet/data/textures): black glass with a soft reflection, a darker window glass, white glass and
# cast iron. They tile (the edges match), so a face that crosses the edge of a tile shows no seam. Run:  ruby tools/make_appliance_textures.rb
require 'zlib'

SIZE = 512
OUT = File.expand_path('../easy_cabinet/data/textures', __dir__)

def png(path, width, height)
  rows = (0...height).map { |y| [0].pack('C') + (0...width).flat_map { |x| yield(x / width.to_f, y / height.to_f).map { |c| c.round.clamp(0, 255) } }.pack('C*') }
  chunk = lambda do |type, data|
    [data.bytesize].pack('N') + type + data + [Zlib.crc32(type + data)].pack('N')
  end
  data = "\x89PNG\r\n\x1a\n".b + chunk.call('IHDR', [width, height, 8, 2, 0, 0, 0].pack('NNCCCCC')) +
         chunk.call('IDAT', Zlib.deflate(rows.join, 9)) + chunk.call('IEND', '')
  File.binwrite(path, data)
  puts "#{File.basename(path)}: #{File.size(path)} bytes"
end

def mix(a, b, t) = a.zip(b).map { |x, y| x + ((y - x) * t) }

# A soft diagonal band of light (the reflection of a window in the glass); `strength` brightens the colour by up to that much.
def band(u, v, at, width)
  d = (u + v - at) % 1.0
  d = [d, 1.0 - d].min
  Math.exp(-((d / width)**2))
end

glass = lambda do |dark, light, streak, second|
  lambda do |u, v|
    shade = (1.0 - Math.cos(2.0 * Math::PI * v)) / 2.0
    base = mix(dark, light, shade * 0.85)
    glow = (band(u, v, 0.5, 0.07) * streak) + (band(u, v, 0.0, 0.035) * second)
    base.map { |c| c + glow }
  end
end

png(File.join(OUT, 'appliance_black_glass.png'), SIZE, SIZE, &glass.call([22, 24, 28], [44, 48, 56], 34.0, 14.0))
png(File.join(OUT, 'appliance_dark_window.png'), SIZE, SIZE, &glass.call([14, 16, 19], [30, 33, 39], 20.0, 8.0))

png(File.join(OUT, 'appliance_white_glass.png'), SIZE, SIZE) do |u, v|
  shade = (1.0 - Math.cos(2.0 * Math::PI * v)) / 2.0
  base = mix([246, 248, 250], [232, 236, 241], shade)
  glow = (band(u, v, 0.5, 0.08) * 9.0) - (band(u, v, 0.0, 0.05) * 6.0)
  base.map { |c| c + glow }
end

random = Random.new(11)
noise = Array.new(SIZE * SIZE) { random.rand(-1.0..1.0) }
png(File.join(OUT, 'appliance_cast_iron.png'), SIZE, SIZE) do |u, v|
  x = (u * SIZE).floor
  y = (v * SIZE).floor
  grain = noise[(y * SIZE) + x] * 5.0
  blotch = Math.sin(u * 2.0 * Math::PI * 5.0) * Math.sin(v * 2.0 * Math::PI * 7.0) * 3.0
  [58 + grain + blotch, 61 + grain + blotch, 66 + grain + blotch]
end
