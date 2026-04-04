```
xcodebuild -project GeminiDesktop.xcodeproj -scheme GeminiDesktop -configuration Release \
  -derivedDataPath ./build/DerivedData CODE_SIGN_IDENTITY="-" CODE_SIGNING_ALLOWED=NO build
./scripts/create-dmg.sh \
  "./build/DerivedData/Build/Products/Release/Gemini Desktop.app" \
  ./build
```