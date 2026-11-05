import { describe, expect, it } from "vitest";

async function load () {
  const SearchControls = (await import("@/pages/posts/common/SearchControls")).default;
  const LStorage = (await import("@/utility/storage/Local")).default;
  return { SearchControls, LStorage };
}

describe("SearchControls", () => {
  it("toggles fullscreen and remembers it", async () => {
    document.body.innerHTML = "<button id=\"toggle-fullscreen\"></button>";
    const { SearchControls, LStorage } = await load();
    void SearchControls.instance;
    expect(document.body.dataset.stFullscreen).toBe("false");

    document.getElementById("toggle-fullscreen").click();
    expect(document.body.dataset.stFullscreen).toBe("true");
    expect(document.getElementById("toggle-fullscreen").classList.contains("active")).toBe(true);
    expect(LStorage.Posts.Fullscreen).toBe(true);
  });

  it("binds once, however often it is requested", async () => {
    document.body.innerHTML = "<button id=\"toggle-fullscreen\"></button>";
    const { SearchControls } = await load();
    expect(SearchControls.instance).toBe(SearchControls.instance);

    document.getElementById("toggle-fullscreen").click();
    expect(document.body.dataset.stFullscreen).toBe("true");
  });

  it("hides corner ribbons as soon as the box is unticked", async () => {
    document.body.innerHTML = "<input type=\"checkbox\" id=\"ssc-corner-ribbons\">";
    document.body.setAttribute("data-st-cornerribbons", "true");
    const { SearchControls, LStorage } = await load();
    void SearchControls.instance;
    const box = document.getElementById("ssc-corner-ribbons") as HTMLInputElement;
    expect(box.checked).toBe(true);

    box.click();
    expect(document.body.getAttribute("data-st-cornerribbons")).toBe("false");
    expect(LStorage.Posts.CornerRibbons).toBe(false);

    box.click();
    expect(document.body.getAttribute("data-st-cornerribbons")).toBe("true");
  });
});
