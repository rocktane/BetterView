#!/bin/zsh
# Regenerates the AppIcon PNGs. Needs rsvg-convert (brew install librsvg).
# Each pixel size comes from the drawing made for it: AppIcon-16.svg for 16 px,
# AppIcon-32.svg for 32 px (simplified, readable in the Dock and Finder lists),
# AppIcon.svg for 64 px and larger.
set -euo pipefail
cd "${0:A:h}/.."
out=Resources/Assets.xcassets/AppIcon.appiconset
images=()
for pt in 16 32 128 256 512; do
  for scale in 1 2; do
    px=$((pt * scale))
    if (( px <= 16 )); then src=Resources/AppIcon-16.svg
    elif (( px <= 32 )); then src=Resources/AppIcon-32.svg
    else src=Resources/AppIcon.svg; fi
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
