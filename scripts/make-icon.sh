#!/bin/zsh
# Regenerates the AppIcon PNGs from Resources/AppIcon.svg. Needs rsvg-convert (brew install librsvg).
set -euo pipefail
cd "${0:A:h}/.."
src=Resources/AppIcon.svg
out=Resources/Assets.xcassets/AppIcon.appiconset
images=()
for pt in 16 32 128 256 512; do
  for scale in 1 2; do
    px=$((pt * scale))
    suffix=""; (( scale == 2 )) && suffix="@2x"
    name="icon_${pt}x${pt}${suffix}.png"
    rsvg-convert -w $px -h $px "$src" -o "$out/$name"
    images+=("    { \"idiom\" : \"mac\", \"size\" : \"${pt}x${pt}\", \"scale\" : \"${scale}x\", \"filename\" : \"$name\" }")
  done
done
{
  print '{\n  "images" : ['
  print -l -- "${(j:,\n:)images}"
  print '  ],\n  "info" : { "author" : "xcode", "version" : 1 }\n}'
} > "$out/Contents.json"
echo "Icône générée dans $out"
