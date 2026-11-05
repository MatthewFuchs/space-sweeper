// SpaceSweeper website: section entrances. Everything is readable without this script.
document.documentElement.classList.add("js");

function buildEntrances() {
  const items = document.querySelectorAll(".reveal");
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
    section.querySelectorAll(".reveal").forEach((el, i) => { el.style.transitionDelay = `${Math.min(i, 6) * 70}ms`; });
  });
  items.forEach((el) => observer.observe(el));
}

buildEntrances();
