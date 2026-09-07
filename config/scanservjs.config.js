/* eslint-disable no-unused-vars */
const options = { paths: ['/usr/lib/scanservjs'] };

module.exports = {
  afterConfig(config) {
    config.port = 8081;
    config.convert = '/usr/bin/magick';
  },
  afterDevices(devices) {},  
  async afterScan(fileInfo) {},
  actions: []
};
