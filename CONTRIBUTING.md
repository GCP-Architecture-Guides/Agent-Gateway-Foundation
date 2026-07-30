<!-- Copyright 2025 Google LLC

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

    https://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.

This code is for PoC environment only.
This demo code is not built for production workload. -->

# Contributing to Agent Gateway Foundation

Thank you for your interest in contributing to this project!

## Contributor License Agreement

Contributions to this project must be accompanied by a Contributor License
Agreement (CLA). You (or your employer) retain the copyright to your contribution;
this simply gives us permission to use and redistribute your contributions as
part of the project.

If you or your current employer have already signed the Google CLA (even if it
was for a different project), you probably don't need to do it again.

Visit <https://cla.developers.google.com/> to see your current agreements or to
sign a new one.

## Code Reviews

All submissions, including submissions by project members, require review.
We use GitHub pull requests for this purpose. Consult
[GitHub Help](https://help.github.com/articles/about-pull-requests/) for more
information on using pull requests.

## Community Guidelines

This project follows [Google's Open Source Community Guidelines](https://opensource.google/conduct/).

## How to Contribute

1. **Fork** the repository on GitHub.
2. **Clone** your fork locally.
3. **Create a branch** for your changes: `git checkout -b feature/your-feature`.
4. **Make your changes**, following the code style of the project.
5. **Test your changes** locally using `deploy_all.sh` (with your own GCP project).
6. **Commit** your changes with a clear, descriptive commit message.
7. **Push** to your fork and **open a Pull Request**.

## Reporting Issues

Please use [GitHub Issues](../../issues) to report bugs or request features.
When reporting a bug, include:
- Your GCP project configuration (without sensitive data)
- The exact error message
- Steps to reproduce

## Code Style

- Shell scripts: follow Google Shell Style Guide
- Terraform: follow Terraform best practices (`terraform fmt`)
- Python: follow PEP 8, use type hints

## Security Vulnerabilities

Please **do not** report security vulnerabilities via GitHub Issues.
See [SECURITY.md](SECURITY.md) if it exists, or contact the maintainers directly.

---

> ⚠️ **Disclaimer:** This code is for PoC environment only.
> This demo code is not built for production workload.
