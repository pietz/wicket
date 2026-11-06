// Running apps through AppKit, for main.sh. Prints JSON on stdout.
//   osascript -l JavaScript apps.js list          all regular apps: name, pid, bundle id, path, launch date
//   osascript -l JavaScript apps.js quit <pid>    asks the app to quit (it may ask to save first)
//   osascript -l JavaScript apps.js force <pid>   force quits the app
// An unknown pid prints null.
ObjC.import("AppKit");

function describe(app) {
  const date = app.launchDate;
  return {
    name: app.localizedName.js,
    pid: app.processIdentifier,
    bundle: app.bundleIdentifier.isNil() ? null : app.bundleIdentifier.js,
    path: app.bundleURL.isNil() ? null : app.bundleURL.path.js,
    launched: date.isNil() ? null : Math.floor(date.timeIntervalSince1970),
  };
}

function find(pid) {
  const app = $.NSRunningApplication.runningApplicationWithProcessIdentifier(Number(pid));
  if (app.isNil() || app.activationPolicy != $.NSApplicationActivationPolicyRegular) return null;
  return app;
}

function run(argv) {
  const [verb, pid] = argv;
  if (verb === "list") {
    return JSON.stringify(
      $.NSWorkspace.sharedWorkspace.runningApplications.js
        .filter((app) => app.activationPolicy == $.NSApplicationActivationPolicyRegular)
        .map(describe),
    );
  }
  const app = find(pid);
  if (!app) return "null";
  if (verb === "quit") app.terminate;
  if (verb === "force") app.forceTerminate;
  return JSON.stringify(describe(app));
}
