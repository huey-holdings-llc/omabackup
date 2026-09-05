# Changelog

All notable changes to this project are documented here. The format follows
Keep a Changelog 1.1.0 and the project uses Semantic Versioning.

## [0.3.0] - Unreleased

### Changed

The widget becomes a public plugin. The backup engine moves into this
repository as `bin/omabackup` over `lib/`, reads a config file instead of
hard-coded paths, and keeps the user's lists and trees in a separate private
data repo. Earlier versions (0.1.0, 0.2.0) were the personal widget over the
author's own private backup script, which is what this engine was ported
from.
