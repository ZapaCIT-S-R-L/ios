// The app icon: ZapaKid/Assets.xcassets/AppIcon.appiconset, one 1024x1024 universal image (Xcode makes the sizes).
// The App Store rejects icons with transparency, so the PNG must have no alpha channel.
import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";

const set = new URL("../ZapaKid/Assets.xcassets/AppIcon.appiconset/", import.meta.url);

test("AppIcon has one 1024x1024 universal iOS image", () => {
  const contents = JSON.parse(readFileSync(new URL("Contents.json", set), "utf8"));
  assert.equal(contents.images.length, 1);
  const [image] = contents.images;
  assert.equal(image.idiom, "universal");
  assert.equal(image.platform, "ios");
  assert.equal(image.size, "1024x1024");
  assert.ok(image.filename);
});

test("the icon file is a 1024x1024 PNG without alpha", () => {
  const { images } = JSON.parse(readFileSync(new URL("Contents.json", set), "utf8"));
  const png = readFileSync(new URL(images[0].filename, set));
  assert.equal(png.subarray(1, 4).toString("latin1"), "PNG");
  assert.equal(png.subarray(12, 16).toString("latin1"), "IHDR");
  assert.equal(png.readUInt32BE(16), 1024, "width");
  assert.equal(png.readUInt32BE(20), 1024, "height");
  const colorType = png[25]; // 2 = RGB, 6 = RGBA, 4 = grey + alpha
  assert.ok(colorType !== 4 && colorType !== 6, "no alpha channel");
});

test("the app uses AppIcon", () => {
  assert.match(readFileSync(new URL("../project.yml", import.meta.url), "utf8"), /ASSETCATALOG_COMPILER_APPICON_NAME: AppIcon\n/);
});
