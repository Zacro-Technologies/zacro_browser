'use strict';
const { Arch } = require('builder-util');
const { validateRuntime } = require('./prepare-runtime.cjs');

module.exports = async (context) => {
  await validateRuntime(context.electronPlatformName, Arch[context.arch]);
};
