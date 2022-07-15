![](Docs/images/photonMapperTeaser.png)

# Hardware Ray Tracing based Progressive Photon Mapper(using Falcor 5.1)

A Progressive Photon Mapper that uses the ray tracing hardware for distribution and collection of photons. 

## Setup
- Setup Falcor 5.1 as described [here](./Falcor_5_1_README.md).
	- Visual Studio 2021 is needed instead of Visual Studio 2019.
- Set Mogwai as Startup Project and build with either `ReleaseD3D12` or `DebugD3D12` Configuration
- Load a Photon Map setup in Mogwai under `File -> Load Script`. The setup scrips are in the `PhotonMapPasses` folder.
- Load a scene in Mogwai under `File -> Load Scene`. 
	- All scenes from the paper can be found in the `Scenes` folder. Load in the `.pyscene` file to get the same results as in the paper.
		- For information about settings used see `Scenes\SceneSettings.csv`.
	- All Falcor-supported scenes with emissive lights and spot/point lights are supported. 

## Render Passes
| Graph | Description |
|---|---|
|VBufferPM | A modified V-Buffer that traces the path until it hits a diffuse surface. |
|RTPhotonMapper | The ray tracing hardware-based progressive photon mapper. Photons are distributed through the scene with ray tracing. An acceleration structure is built with the distributed photons that are then collected with an infinite small ray. The user has control over the number of photons and needs to ensure that the photon buffer is big enough. All other functions are explained in the UI by hovering over the question mark to the right side of a function.
|HashPPM | An alternative implementation of the RTPhotonMapper using a hash grid for collection. The photons are still distributed with ray tracing but are now stored in a hash map. Like with the RTPhotonMapper the user has to ensure that the photon buffer is big enough. All other functions are explained in the UI by hovering over the question mark to the right side of a function.
|StochHashPPM | An alternative implementation of the RTPhotonMapper using a stochastic hash grid for collection. Photons are distributed via ray tracing shader and are stored in a hash grid. On collision, the photon is randomly overwritten. Settings are explained in the small question mark on the right side of the functions in the UI.

## Source Code

We recommend Visual Studio 2021 for navigating the source code. The code for our Photon Mappers can be found in the respective folder under `Source/RenderPasses`.
The names for each Pass is listed here:
| Pass | Name in Project |
|---|---|
|VBufferPM | VBufferPM |
|RTPhotonMapper | PhotonMapper|
|HashPPM | PhotonMapperHash|
|StochHashPPM| PhotonMapperStochasticHash|