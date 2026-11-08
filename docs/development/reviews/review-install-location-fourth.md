- [P2] cpa-dr/scripts/packaging/location.sh:119 — Native 私有配置的 sudo 重入丢失关联身份校验：配置祖先权限 0700、install.json 与部署记录的 install_id 不同时，UID 65534 执行稳定入口 `install --deployment native --role backup --data-dir TARGET --yes` 仍进入 sudo；按捕获参数以 root fixture 重放已触达原生安装函数，而 root 直接稳定入口正确拒绝身份不符。
VERDICT: REWORK
前三轮十一项原失败输入均已关闭。
AC1–AC3、AC5–AC7：覆盖；AC4：DEVIATED，Native 重入需补验关联身份。
AC8–AC9：证据及文档已审；六项 integration、9项页面测试、文档/结构、75文件语法/ShellCheck复跑通过，冻结一致。
Docker/CGI/SSH/首备证据有效；Native systemd、sudo、软件源模拟边界明确。

---

普通独立审查；未启用 Athena 状态库。基线 HEAD：5282bd97ce566192f84684dee9e4f53942e93a23。审查源码路径/模式/内容集合 SHA256：ed731f80cb88ce2d4fbdd1769005252df1d4192e6ed4558983bd64e0180b36b7。原始输出在上方原样保留，本段仅补充冻结元数据。
