// Copy buttons for every .command block. Shared by both pages: this used to be
// inline in index.html, so the broken-screen page had no script at all and any
// copy button added there would have done nothing.
document.querySelectorAll('.copy').forEach((button) => {
  button.addEventListener('click', async () => {
    const command = button.dataset.copy;
    try {
      await navigator.clipboard.writeText(command);
    } catch {
      const textArea = document.createElement('textarea');
      textArea.value = command;
      document.body.append(textArea);
      textArea.select();
      document.execCommand('copy');
      textArea.remove();
    }
    button.textContent = '✓ Copied';
    window.setTimeout(() => { button.textContent = '⧉ Copy'; }, 1600);
  });
});
