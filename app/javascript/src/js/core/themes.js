import Page from "@/utility/Page";
import CStorage from "@/utility/storage/Cookie";
import LStorage from "@/utility/storage/Local";

const Theme = {};

Theme.Values = {
  "Theme": ["Main", "Extra", "Palette", "Font", "StickyHeader", "Navbar", "Gestures", "Logo"],
  "Posts": ["WikiExcerpt", "StickySearch", "AutocompleteCache", "VideoPlayer"],
  "Site": ["Events", "TimeSwitch"],
};

for (const [label, settings] of Object.entries(Theme.Values)) {
  for (const one of settings) {
    Object.defineProperty(Theme, one, {
      get () { return LStorage.Theme[one]; },
      set (value) {
        // This has the unintended side effect of setting
        // attribute values that don't exist on the body.
        LStorage[label][one] = value;

        $("body").attr("data-th-" + one.toLowerCase(), value);
      },
    });
  }
}

Theme.initialize_selector = function () {
  // Any modern browser should support localStorage.
  if (!LStorage.provider.isAvailable) {
    $("#no_save_warning").show();
    return false;
  }

  for (const [label, settings] of Object.entries(Theme.Values)) {
    for (const one of settings)
      $(`#${label}_${one}`)
        .val(LStorage[label][one] + "")
        .on("change", (event) => {
          const data = event.target.value;
          Theme[one] = data;
        });
  }
};

Theme.initialize_buttons = function () {
  if (!LStorage.provider.isAvailable) return;

  if (CStorage.Site.MascotID !== 0) {
    $("#mascot-state").show();
    $("#mascot-value").text(CStorage.Site.MascotID);
    $("#mascot-reset").on("click", () => {
      CStorage.Site.MascotID = 0;
      $("#mascot-state").hide();
    });
  }

  if (LStorage.Posts.Recommendations === "closed") {
    $("#recommended-state").show();
    $("#recommended-reset").on("click", () => {
      LStorage.Posts.Recommendations = "artist";
      $("#recommended-state").hide();
    });
  }
};

Theme.update_meta_theme_color = function () {
  const metaTag = document.querySelector('meta[name="theme-color"]');
  if (!metaTag) return;
  const color = getComputedStyle(document.body).backgroundColor;
  if (color) metaTag.content = color;
};

$(() => {
  Theme.update_meta_theme_color();
  if (Page.matches("static", "theme")) {
    Theme.initialize_selector();
    Theme.initialize_buttons();
  }
});

export default Theme;
