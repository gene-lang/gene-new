// Resolves after a delay so a test can remove the outlet while it loads.
await new Promise(resolve => setTimeout(resolve, 40));
export function main(root) {
  root.dataset.mounted = 'late';
  root.harness_controller = { update() {}, key() { return false; }, dispose() {} };
}
