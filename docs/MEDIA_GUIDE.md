# Maintaining the README media

## GIFs

Commit GIFs alongside the README and use relative image paths:

```markdown
![Ontology connecting assets, faults, tasks, and resources](docs/assets/demos/ontology.gif)
![Coco skills investigating and validating P-204](docs/assets/demos/skills.gif)
![Streamlit command center](docs/assets/demos/streamlit.gif)
![Slack reporting](docs/assets/demos/slack.gif)
![Delivered daily automation email](docs/assets/demos/automation-email.gif)
```

Each recording should have a short caption explaining the decision it demonstrates. Keep text readable; favor short clips with a clear start and result. Put secondary recordings in `<details>` blocks to keep the main page easy to scan. A collapsed section reduces visual clutter but is not a guarantee of deferred image loading.

The README uses stable filenames, so replacing a GIF does not require changing the Markdown. The ontology, Slack, and email GIFs were provided by the team; skills and Streamlit highlights are extracted from the supplied demo video where supported by its visible content.

## Slides and PowerPoint

Use PNG/JPEG slide previews in the README and link them to the slide gallery or a committed deck file. This keeps the visual content readable without relying on an embedded presentation player.

```markdown
[![Solution workflow](docs/assets/slides/03-workflow.png)](docs/SLIDES.md)
```

After adding a real PPTX or PDF to `docs/deck/`, link it explicitly:

```markdown
[Download the PowerPoint](docs/deck/manufacturing-copilot.pptx)
[Open the PDF deck](docs/deck/manufacturing-copilot.pdf)
```

Do not add these download links until the files exist. The earlier PDF is no longer available at the original attachment path, so this package uses the slide images preserved from that review. No editable PPTX was supplied. GitHub README Markdown is not a PowerPoint player; link to an external viewer if slide navigation or animation is important.

The default README displays a title image, selected demo GIFs, and slide 2–4 thumbnails. The full-size gallery lets readers inspect the dense architecture without crowding the main page.

## Full video

The package includes the supplied MP4 under `docs/assets/demos/`. A linked poster in the README opens that file. For public hosting, a GitHub Release asset or a video-hosting URL is often more convenient than committing the full recording; update the poster's destination after you choose a hosting location. This documentation task does not upload or publish anything.

## Source guidance

GitHub recommends relative paths for repository images and links so they follow the checked-out branch:

- [About READMEs](https://docs.github.com/en/repositories/managing-your-repositorys-settings-and-features/customizing-your-repository/about-readmes)
- [Images and writing syntax](https://docs.github.com/en/get-started/writing-on-github/getting-started-with-writing-and-formatting-on-github/basic-writing-and-formatting-syntax)
