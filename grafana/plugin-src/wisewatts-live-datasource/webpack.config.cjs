const path = require('path');

module.exports = {
  mode: 'production',

  entry: './src/module.tsx',

  output: {
    filename: 'module.js',
    path: path.resolve(__dirname, 'dist'),
    library: {
      type: 'system',
    },
    clean: false,
  },

  externalsType: 'system',

  externals: {
    react: 'react',
    'react-dom': 'react-dom',
    '@grafana/data': '@grafana/data',
    '@grafana/runtime': '@grafana/runtime',
    '@grafana/ui': '@grafana/ui',
  },

  resolve: {
    extensions: ['.tsx', '.ts', '.js'],
  },

  module: {
    rules: [
      {
        test: /\.tsx?$/,
        exclude: /node_modules/,
        use: {
          loader: 'ts-loader',
          options: {
            transpileOnly: true,
          },
        },
      },
    ],
  },

  optimization: {
    minimize: false,
  },

  devtool: false,
};
