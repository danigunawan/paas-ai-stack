# Contributing to PaaS AI Stack

Thank you for your interest in contributing! This guide will help you get started.

## Ways to Contribute

- **Bug Reports**: Found a bug? Open an issue with reproduction steps
- **Feature Requests**: Have an idea? Open an issue to discuss
- **Code**: Fix bugs or implement features via pull requests
- **Documentation**: Improve README, add examples, fix typos
- **Testing**: Test on different platforms and report issues

## Development Setup

1. Fork and clone the repository
2. Copy `.env.template` to `.env` and configure
3. Run `make bootstrap` to start the stack
4. Make your changes
5. Test thoroughly

## Pull Request Process

1. **Create a branch** from `main`:
   ```bash
   git checkout -b feature/your-feature-name
   # or
   git checkout -b fix/issue-description
   ```

2. **Make your changes**:
   - Follow existing code style
   - Update documentation if needed
   - Test on your platform (note which OS in PR)

3. **Commit with clear messages**:
   ```bash
   git commit -m "feat: add support for X"
   git commit -m "fix: resolve Y issue on Windows"
   git commit -m "docs: update README with Z"
   ```

4. **Push and open a PR**:
   - Describe what changed and why
   - Reference any related issues
   - Note which platform(s) you tested on

## Code Guidelines

### Shell Scripts (`scripts/`)
- Use `#!/usr/bin/env bash` shebang
- Quote variables: `"$VAR"` not `$VAR`
- Check for errors: `set -e` or explicit error handling
- Support cross-platform (Linux, macOS, Windows/Git Bash)
- Use functions for reusable logic

### Docker Compose
- Pin image versions for reproducibility
- Use health checks where applicable
- Document environment variables

### Documentation
- Keep README.md updated
- Add comments for complex logic
- Include examples where helpful

## Testing Checklist

Before submitting a PR, please test:

- [ ] Fresh install (`make bootstrap` from scratch)
- [ ] All services start correctly
- [ ] API endpoints are accessible
- [ ] Sample app deploys successfully

**Platform testing** (note which you tested):
- [ ] Linux
- [ ] macOS
- [ ] Windows (Docker Desktop)

## Reporting Issues

When reporting bugs, please include:

1. **Platform**: OS, Docker version
2. **Steps to reproduce**: What you did
3. **Expected behavior**: What should happen
4. **Actual behavior**: What actually happened
5. **Logs**: Relevant error messages or logs

## Questions?

- Open a GitHub Discussion for general questions
- Open an Issue for bugs or feature requests

Thank you for contributing!
