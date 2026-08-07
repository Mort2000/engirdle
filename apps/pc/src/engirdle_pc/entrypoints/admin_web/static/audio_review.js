(() => {
  const audio = document.querySelector("#review-audio");
  if (!audio) return;

  let stopAtSeconds = null;
  document.querySelectorAll("[data-audio-start]").forEach((button) => {
    button.addEventListener("click", () => {
      audio.currentTime = Number(button.dataset.audioStart) / 1000;
      stopAtSeconds = Number(button.dataset.audioEnd) / 1000;
      void audio.play();
    });
  });
  audio.addEventListener("timeupdate", () => {
    if (stopAtSeconds !== null && audio.currentTime >= stopAtSeconds) {
      audio.pause();
      stopAtSeconds = null;
    }
  });
})();
