'use strict';

// 预览要用的本机文件：让原生读内容，读到了回调。

// ---------- 读本机文件（经原生桥） ----------
const fileReads = new Map();
let fileReqSeq = 0;

function readLocalFile(path, base) {
  return new Promise(resolve => {
    if (!hasBridge()) { resolve({ path, error: '预览模式下读不了本机文件' }); return; }
    const reqId = ++fileReqSeq;
    fileReads.set(reqId, resolve);
    postNative('readFile', { path, base, reqId });
  });
}

window.onFileRead = data => {
  const resolve = fileReads.get(data.reqId);
  if (!resolve) return;
  fileReads.delete(data.reqId);
  resolve(data);
};
