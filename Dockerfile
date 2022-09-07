FROM homebrew/ubuntu22.04:master

COPY --chown=linuxbrew:linuxbrew . /home/linuxbrew/.linuxbrew/Homebrew/Library/Taps/homebrew/homebrew-test-bot
