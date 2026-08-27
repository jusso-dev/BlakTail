// Replay with:
//   LP_CONSOLE_URL=https://console.example/sign-in \
//   LP_CONSOLE_EMAIL=owner@example.test \
//   LP_CONSOLE_PASSWORD='…' \
//   lightpanda agent apps/console/scripts/lightpanda-ui.pandascript.js
//
// `$LP_*` placeholders are substituted by Lightpanda. Do not commit real secrets.

const page = new Page();
await page.goto("$LP_CONSOLE_URL");
page.waitForSelector("h1");
page.fill({ selector: "input[name='email']", value: "$LP_CONSOLE_EMAIL" });
page.fill({ selector: "input[name='password']", value: "$LP_CONSOLE_PASSWORD" });
page.click({
  selector: "[data-testid='sign-in-submit'], .sign-in-card form button[type='submit']",
});
page.waitForScript(
  "document.querySelector('h1') && document.querySelector('h1').textContent === 'Devices'",
  { timeout: 20000 },
);

const devices = page.extract({
  heading: "h1",
  empty: ".empty-state h2",
  nav: [{ selector: "nav[aria-label='Console'] a", fields: { label: "" } }],
});

page.click({
  selector: "[data-testid='nav-acls'], nav[aria-label='Console'] a[href='/acls']",
});
page.waitForScript(
  "document.querySelector('h1') && document.querySelector('h1').textContent === 'Access'",
  { timeout: 15000 },
);
page.waitForSelector("h2");

return {
  devices,
  access: page.extract({
    heading: "h1",
    groups: "h2",
    save: "[data-testid='acl-save'], .actions button",
  }),
};
