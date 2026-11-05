// SpaceSweeper website: the live space map, the stage slider, and section entrances.
// Everything works without this script: tiles are buttons with their text, the stages list is readable.
document.documentElement.classList.add("js");

// Sample Mac for the hero map. Ratings and explanations are the app's own (Models/HelpContent.swift).
const KINDS = [
  { name: "Your files", size: 48, level: "review", rating: "Review", what: "Documents, photos, videos and music.", ifDeleted: "Can't be recreated. Back up first." },
  { name: "App data", size: 21, level: "careful", rating: "Careful", what: "Application Support and app containers.", ifDeleted: "Loses settings, saves, chat history or offline content." },
  { name: "Other downloads", size: 14, level: "review", rating: "Review", what: "Anything else in Downloads.", ifDeleted: "Download it again if you still need it." },
  { name: "Caches", size: 9, level: "safe", rating: "Safe", what: "~/Library/Caches and browser caches.", ifDeleted: "Apps rebuild them; they may be slower once." },
  { name: "Build output", size: 7, level: "safe", rating: "Safe", what: "Xcode DerivedData, node_modules, build folders.", ifDeleted: "Recreated on the next build or install." },
  { name: "Virtual machines", size: 6, level: "careful", rating: "Careful", what: "Emulators, simulators and VM disks.", ifDeleted: "Everything inside the VM is lost." },
  { name: "Installers", size: 4, level: "safe", rating: "Safe", what: ".dmg and .pkg files in Downloads.", ifDeleted: "Not needed once the app is installed." },
  { name: "Package downloads", size: 3, level: "safe", rating: "Safe", what: "npm, Gradle and Homebrew downloads.", ifDeleted: "Downloaded again when needed." },
  { name: "System & vaults", size: 2.5, level: "protected", rating: "Protected", what: "macOS, Keychains, iCloud Drive, Mail, Photos.", ifDeleted: "SpaceSweeper never deletes these." },
  { name: "Logs", size: 1, level: "safe", rating: "Safe", what: "~/Library/Logs.", ifDeleted: "Only used for troubleshooting." },
];
const TILE_COLOURS = ["var(--tile-1)", "var(--tile-3)", "var(--tile-2)", "var(--tile-4)", "var(--tile-5)"];

// Squarified treemap, the same layout the app's Folders map uses.
function squarify(sizes, width, height) {
  const total = sizes.reduce((a, b) => a + b, 0);
  const scale = (width * height) / total;
  const rects = [];
  let x = 0, y = 0, w = width, h = height, row = [];
  const worst = (r, side) => {
    const areas = r.map((i) => sizes[i] * scale);
    const sum = areas.reduce((a, b) => a + b, 0);
    return Math.max((side * side * Math.max(...areas)) / (sum * sum), (sum * sum) / (side * side * Math.min(...areas)));
  };
  const place = (r) => {
    const sum = r.reduce((a, i) => a + sizes[i] * scale, 0);
    if (w >= h) {
      const cw = sum / h; let cy = y;
      r.forEach((i) => { const ch = (sizes[i] * scale) / cw; rects[i] = [x, cy, cw, ch]; cy += ch; });
      x += cw; w -= cw;
    } else {
      const rh = sum / w; let cx = x;
      r.forEach((i) => { const cw = (sizes[i] * scale) / rh; rects[i] = [cx, y, cw, rh]; cx += cw; });
      y += rh; h -= rh;
    }
  };
  sizes.forEach((_, i) => {
    const side = Math.min(w, h);
    if (row.length === 0 || worst([...row, i], side) <= worst(row, side)) row.push(i);
    else { place(row); row = [i]; }
  });
  if (row.length) place(row);
  return rects;
}

function buildMap() {
  const map = document.querySelector("[data-space-map]");
  const readout = document.querySelector("[data-readout]");
  if (!map || !readout) return;
  const gap = 6;
  const draw = () => {
    const { width, height } = map.getBoundingClientRect();
    const rects = squarify(KINDS.map((k) => k.size), width, height);
    map.querySelectorAll(".tile").forEach((tile, i) => {
      const [x, y, w, h] = rects[i];
      Object.assign(tile.style, { left: `${x + gap / 2}px`, top: `${y + gap / 2}px`, width: `${Math.max(0, w - gap)}px`, height: `${Math.max(0, h - gap)}px` });
      tile.classList.toggle("small", w < 150 || h < 90);
      tile.classList.toggle("tiny", w < 70 || h < 46);
    });
  };
  const show = (index) => {
    const kind = KINDS[index];
    map.querySelectorAll(".tile").forEach((t, i) => t.setAttribute("aria-pressed", String(i === index)));
    readout.innerHTML = "";
    const title = document.createElement("p");
    const name = document.createElement("strong");
    name.textContent = `${kind.name}: `;
    const rating = document.createElement("span");
    rating.className = "rating";
    rating.dataset.level = kind.level;
    rating.textContent = kind.rating;
    title.append(name, rating);
    const what = document.createElement("p");
    what.textContent = kind.what;
    const consequence = document.createElement("p");
    consequence.textContent = `If you delete it: ${kind.ifDeleted}`;
    readout.append(title, what, consequence);
  };
  map.innerHTML = "";
  KINDS.forEach((kind, i) => {
    const tile = document.createElement("button");
    tile.type = "button";
    tile.className = "tile";
    tile.style.background = kind.level === "protected" ? "#4a5578" : TILE_COLOURS[i % TILE_COLOURS.length];
    tile.setAttribute("aria-label", `${kind.name}, ${kind.size} gigabytes, rated ${kind.rating}`);
    tile.innerHTML = `<span class="name"></span><span class="size"></span>`;
    tile.querySelector(".name").textContent = kind.name;
    tile.querySelector(".size").textContent = `${kind.size} GB`;
    tile.addEventListener("click", () => show(i));
    map.append(tile);
  });
  draw();
  show(3); // Caches: a Safe example to start with
  new ResizeObserver(draw).observe(map);
}

function buildStages() {
  const control = document.querySelector("[data-stages]");
  if (!control) return;
  const slider = control.querySelector("input");
  const clause = document.querySelector("[data-stage-clause]");
  const detail = document.querySelector("[data-stage-detail]");
  const picture = document.querySelector("[data-stage-picture]");
  const names = control.querySelectorAll(".stage-names span");
  const stages = [...document.querySelectorAll("[data-stage]")].map((el) => ({
    clause: el.dataset.clause, detail: el.textContent.trim(), image: el.dataset.image, alt: el.dataset.alt,
  }));
  const update = () => {
    const stage = stages[Number(slider.value)];
    clause.textContent = stage.clause;
    detail.textContent = stage.detail;
    picture.style.opacity = "0";
    setTimeout(() => { picture.src = stage.image; picture.alt = stage.alt; picture.style.opacity = "1"; }, 120);
    names.forEach((n, i) => (i === Number(slider.value) ? n.setAttribute("aria-current", "step") : n.removeAttribute("aria-current")));
    slider.setAttribute("aria-valuetext", names[Number(slider.value)].textContent);
  };
  slider.addEventListener("input", update);
}

function buildEntrances() {
  const items = document.querySelectorAll(".reveal, .shutter");
  if (!("IntersectionObserver" in window)) { items.forEach((el) => el.classList.add("in")); return; }
  const observer = new IntersectionObserver((entries) => {
    entries.forEach((entry) => {
      if (!entry.isIntersecting) return;
      entry.target.classList.add("in");
      observer.unobserve(entry.target);
    });
  }, { threshold: 0.12 });
  // Stagger the parts of each section: heading, then text, then picture.
  document.querySelectorAll("section, .steps > li").forEach((section) => {
    section.querySelectorAll(".reveal").forEach((el, i) => { el.style.transitionDelay = `${i * 80}ms`; });
  });
  items.forEach((el) => observer.observe(el));
}

buildMap();
buildStages();
buildEntrances();
