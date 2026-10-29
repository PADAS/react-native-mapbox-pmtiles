import { NativeModules } from 'react-native';

export type TileExtension ='mvt' | 'pbf' | 'png' | 'jpg' | 'webp';

interface RNMapboxPMTilesModule {
  install(directory: string): void;
}

const { RNMapboxPMTiles } = NativeModules as { RNMapboxPMTiles?: RNMapboxPMTilesModule };

export const PMTILES_HOST = 'https://pmtiles.local';

export const install = (directory: string) => {
  if (!RNMapboxPMTiles) {
    throw new Error('react-native-mapbox-pmtiles: native module not linked, rebuild the app');
  }
  RNMapboxPMTiles.install(directory);
};

export const tileUrl = (name: string, extension: TileExtension) => `${PMTILES_HOST}/${name}/{z}/{x}/{y}.${extension}`;
