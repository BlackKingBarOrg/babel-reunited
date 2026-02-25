export default {
  resource: "admin.adminPlugins.show",

  path: "/plugins",

  map() {
    this.route("ai-translator" );
  },
};
