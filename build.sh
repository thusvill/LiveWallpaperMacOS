clear
make
cp -rfv LiveWallpaper.app FinalPKG/
mkdir FinalPKG/LiveWallpaper.app/Contents/Resources
cp vendor/ffmpeg FinalPKG/LiveWallpaper.app/Contents/Resources/ffmpeg

echo "Packing to DMG"
hdiutil create -volname "LiveWallpaper" -srcfolder FinalPKG -ov -format UDZO LiveWallpaper-Silicon.dmg
echo "Done."